# The orchestration plane

The durability plane stores rows and answers queries; it never decides
anything. Deciding is this plane's job. Given a session that survives
being killed at any instant — its stores, transactions, and
compare-and-swap discipline are in `docs/architecture/durability.md`, and
everything below leans on them — the orchestration plane answers a harder
question: what happens next, what must be durable before it happens, and
how a process killed at that instant resumes without repeating itself. A
pure package, `machine`, computes the decision; an OTP package,
`runtime`, carries it out.

## An operation is one unit of strand work

A **strand** is a named line of work — the main conversation, a subagent,
a parallel attempt — whose durable footprint is a handful of registers
(the durability doc covers them). An **operation** is one accepted unit
of work on a strand: a conversational run, a standalone compaction, or a
navigation to another point in the tree. A strand has at most one open
operation, and `strand.state` names it. `op.meta` holds that operation's
immutable half, written once at acceptance: its id, its strand, the
strand's leaf *before* it started, its start time, and its intent.
`op.state` holds everything that changes, and has no finished variant —
an ended operation has no state at all, because the terminal transaction
deletes the register and moves the outcome to `strand.last_result`, which
recovery never reads.

## The machine decides; the runtime executes

The machine's whole surface is one function, frozen in the
implementation spec:

```gleam
pub fn next_action(op: Operation, state: OperationState, in: PlannerInputs) -> Action
```

It reads a durable state and a bundle of inputs and returns one of six
actions. It performs no I/O, keeps nothing between calls, and cannot
crash.

- **`Transition(next, tx)`** — commit `tx`, whose writes make `next` true,
  then plan again.
- **`Dispatch(intent, next, tx)`** — commit the intent transaction, *then*
  perform the described external effect.
- **`AwaitEffect(key)`** — the machine needs an observation it lacks; the
  key names which one.
- **`Wait(until)`** — nothing to do until a stated durable wake point.
- **`Finish(result, tx)`** — commit the terminal transaction; the
  operation ceases to exist.
- **`Fault(report)`** — the inputs or the durable state are corrupt, so
  the caller must fault. This sixth variant extends a frozen contract,
  since a total function needs a value where a partial one would crash;
  `protocol-change/002` records it.

The runtime does the other half: it reads registers, calls hooks, spawns
provider requests and tool executions, commits transactions, and sets
timers. It decides nothing about the conversation, and a transaction it
commits is one the machine built, expectations and all.

Purity here buys crash semantics you can test. Because `next_action`
keeps nothing between calls, the state after a crash is exactly the state
before it — whatever the last commit made durable — so replaying the
machine from decoded registers *is* the crash case. The machine's
scenario tests rebuild `PlannerInputs` from the store before every step,
and the driver re-reads its registers on every pass.

## The durable program counter

`op.state` is a **total** value: it never depends on a previous state, so
recovery reads this one register and knows where it was. Every durable
transition replaces it, and its completeness is what lets recovery
reconstruct nothing.

Small captured values live inline — the run's settings snapshot, a step's
configuration and stream options, the retry policy, the reserved ids of
an effect in flight. Large stable payloads live in sibling
operation-owned registers under deterministic keys:
`op.tool_args/{op}:{step}:{index}` for a call's post-clearance arguments,
`op.preparation/{op}:{task}` for a summary's frozen input,
`pending.entry/{id}` for a message durable but not yet in the tree — all
written once, all deleted by the terminal transaction.

Captured means captured: the configuration snapshotted when a step became
ready is the one recovery uses, even if the strand's has since changed
and even if the captured model no longer resolves. An unresolvable
identity becomes an in-band configuration failure at the boundary where
the effect would have run, never a silent substitution.

## The effect sandwich

Between two commits sits the only genuinely uncertain window in the
system.

```
  commit  intent   op.state = effect_pending, holding reserved ids R
                   (the response or result entry) and U (the usage row)
          ──────────────────────────────────────────────────────────────
          do it    the provider request, tool execution, deferred fetch,
                   or summary request runs — nothing durable happens here
          ──────────────────────────────────────────────────────────────
  commit  settle   entry R + usage row U + leaf move + next op.state,
                   in one atomic transaction
```

The ids are the trick. `R` and `U` are minted *before* the effect starts
and persisted in the intent, so the settlement writes under ids already
promised — and so does a synthetic settlement written by recovery days
later.

A crash lands on one side of that window or the other. Before the intent
commit the effect never started; after the settle commit it is fully
recorded. Inside, the state says `effect_pending` and the truth is
unknown — which is what the runtime reports when it reloads that state
and finds no live effect to match. It hands the machine an *orphan*
observation, and the machine decides:

- **An assistant request or deferred poll** is wholly uncertain. Recovery
  commits a synthetic zero-usage response under the reserved ids —
  errored while running, aborted under cancellation — and follows
  ordinary classification: another attempt if the captured retry policy
  has attempts left, failure drain at the cap. The ids are consumed
  rather than abandoned, so ledger and tree stay in step. Its content is
  empty, since Loom persists no streamed frames (there is no list store
  in the frozen transaction type).
- **A tool call** consults its **replay policy**, declared at intent and
  persisted there. `ReplaySafe` re-executes with the persisted arguments
  under the same reserved result id — and only if the tool's *current*
  registration still declares safe replay, so revoking a declaration
  takes effect immediately. `ReplayNever` never re-executes: the machine
  synthesizes an interrupted result under the reserved id, carrying an
  explicit warning that the call's outcome is unknown.

Nothing runs twice, every tool call has a result, and billing survives
the crash — at the price of one legitimate divergence, which the
interleave harness asserts rather than hides: a `ReplayNever` call
interrupted mid-flight yields the synthetic result, not the real one.

Hooks sit outside the sandwich. Run-start injection, request admission,
structural decisions, threshold checks, and the run-end hook carry no
effect intent and are safe to rerun, so they arrive as observations and
the transition consuming one commits once.

## The state space at a glance

Three constructors, matching the three intents. A state whose kind
disagrees with its operation's intent is corruption.

```
RunState          control · settings · phase · inbox · latest_assistant
  phase = Starting
        | Checkpoint     continuation · trigger · threshold_checked · skip_inbox_once
        | Assistant      Ready | EffectPending | RetryWait
        | Tools          per call: Planned | EffectPending | OutcomeReady | Completed
        | Compacting     reason · structural · resume_after
        | AwaitingDeferred   Suspended | EffectPending
        | FailureDrain   error · provenance

CompactionState   control · custom_instructions · structural
NavigationState   control · navigation (Unsummarized | Summarized)

control     = Running | CancelRequested(requested_at, drained_steer, drained_follow_up)
inbox       = steer · follow_up · writes       (reserved entry ids only)
structural  = Deciding(task) | Generating(task, Ready | EffectPending | RetryWait)
```

`machine/operation.gleam` carries the full tree with the invariant of
every constructor beside it; the sketch above is a map of that file. A
**checkpoint** is the durable decision point between steps: `trigger`
names the newest appended entry that created the boundary, `continuation`
says whether another assistant turn is owed (`NeedAssistant`) or the run
may end (`MayFinish`), and the two flags keep the decision idempotent
under crashes. The **inbox** holds reserved entry ids, never payloads —
those live in `pending.entry`, so a queued id has a register *or* an
entry *or* neither, never both.

## The drive loop

The strand driver is an actor, and its loop is the machine's contract
read literally:

```
load registers  →  build PlannerInputs  →  next_action  →  act  →  repeat
```

**Load** re-reads `strand.state`, `op.meta`, `op.state`, `strand.config`,
and `strand.leaf` on *every* pass, then fetches exactly what the loaded
state names: the assistant entry behind a tool batch, the deferred handle
behind a suspended poll, the pending payloads for every queued id, the
structural preparation, the operation's tool-args and preparation keys.
No process-local memory of the durable state exists to go stale, so a
pass after a restart runs the same code as a pass mid-run.

**Build inputs.** `PlannerInputs` adds the clock's reading, the seqs the
emitted transactions will expect, the threshold-compaction signal,
whether this pass may spend a deferred poll permit, a freshly seeded id
generator (the machine mints several ids per call, so reusing one would
mint collisions), and one observation.

An **observation** is what the runtime produced for the machine since the
last plan: a hook's output, an effect's settlement, or an orphan report.
The driver queues them and hands over one per pass. `AwaitEffect(key)`
asks for a specific one, and the driver resolves the key three ways. A
**hook key** runs the hook synchronously and yields its observation at
once. An **effect key** with a matching live effect parks the driver
until the outcome arrives as a message — effect tokens are compared
structurally against the durable state's reserved identities, so an
outcome from a previous incarnation can never pass for a live one. An
**effect key** with no live effect to match is the crash case, and yields
the orphan observation.

**Act.** `Transition` and `Finish` commit and loop. `Dispatch` commits the
intent transaction and only then spawns the effect — an unlinked,
monitored process whose outcome comes back as a message. `Wait` sets a
retry timer, or parks the strand until the next poll tick grants a
deferred permit. Both of those delays go through an injected timer seam
rather than the VM's timer wheel directly, so a simulated session runs
them on logical time; production passes `effects.real_timers()`. `Fault` stops the actor abnormally, as does exhausting
the loop's fuel bound of ten thousand planning steps.

Two failure paths deserve naming. A commit refused with
`StaleExpectation` means someone else — usually an admission from the
session API — won the seq race; the driver reloads and plans again,
pushing any unconsumed observation back to the front of its queue. And an
effect process that dies without reporting settles **in band**: the
monitor fires and the driver feeds itself a transport-failure response or
a synthetic tool error through the ordinary outcome path, so a dead
worker never wedges a strand or faults one.

## One run, end to end

Each step below is at least one commit, and a crash between any two of
them resumes at the next.

1. **Acceptance** asks `accept_prompt` for a plan and commits it as one
   transaction: captured next-run items placed as entries, the prompt
   entries after them, the leaf moved, `op.meta` and `op.state` written,
   `strand.state.current_operation` set — expecting the strand-state seq
   the caller read, so a concurrent acceptance loses its expectation and
   reports a busy strand. Then the doorbell rings.
2. **The checkpoint procedure**, reached first by consuming the run-start
   hook's injections, runs in a fixed order, each step that does anything
   being its own commit: apply accepted deferred writes; drain steer
   input per the run's drain mode; check the compaction threshold; then
   start a generation step (`NeedAssistant`) or, at a `MayFinish`
   boundary, drain follow-ups and otherwise consult the run-end hook and
   finish. Both idempotence flags live here: `threshold_checked` names
   the trigger whose compaction check already ran, so a boundary is never
   checked twice, and a drain sets `skip_inbox_once` on the checkpoint it
   produces, so a crash mid-drain cannot turn a one-at-a-time drain into
   an all-item drain.
3. **Generation** snapshots the configuration, stream options, and retry
   policy, then commits `Assistant(Ready)` expecting the op-state seq
   *and* the configuration seq, so a configuration change racing the
   snapshot is caught. The pre-request hook refuses — an unavailable
   model becomes a failure drain, with nothing fabricated — or admits,
   and the sandwich closes around the request.
4. **Settlement** classifies the response and commits the response entry,
   the leaf move, the usage row under the reserved id, and the next state
   as one transaction: a tool batch, a checkpoint, a retry wait, a
   compaction, a deferred suspension, or a failure drain.
5. **A tool batch** plans one call per tool-call block in source order,
   reserving every result id up front; each call then walks
   planned → effect-pending → outcome-ready → completed. Clearance
   persists the effective arguments and commits the intent; execution
   runs; the finalized result is *staged* into `pending.entry`;
   materialization places the contiguous staged run at the frontier into
   the tree in source order, deletes those registers, and writes any
   tool-reported usage. Staging and placement are separate commits because
   parallel execution settles out of order while the tree stays ordered.
6. **The terminal transaction** publishes any structural result, deletes
   `op.meta`, `op.state`, every tool-args and preparation key the runtime
   listed, and every pending id the operation still owns; writes
   `strand.last_result`; and clears `strand.state.current_operation`,
   preserving next-run ids admitted concurrently.

## Strands, queues, and doorbells

Four queues feed a strand, and every admission is a durable commit plus
an ephemeral nudge — never a process message carrying a payload. One
transaction mints the item's entry id, writes its payload to
`pending.entry/{id}`, and appends the id to a queue, expecting the seq of
whichever register it changes.

- **steer** and **follow-up** attach to an open run with running control.
  Steer drains at a checkpoint before generating, follow-up only at a
  `MayFinish` boundary, each under its own mode: `ConsumeAll` or
  `OneAtATime`.
- **writes** are deferred custom tree writes, admitted in every control
  state including cancelling and applied even during reconciliation, so
  they survive an abort.
- **next-run** items belong to the strand rather than any operation:
  admitted in any state, never starting a run, consumed by the next
  acceptance, preserved by terminal transactions.

**Abort** is routed through the strand driver rather than committed by
the caller, so its marker serializes with the strand's own transitions.
The first abort commits `CancelRequested` and **drains without
deleting**: steer and follow-up ids move into the drained lists and the
inbox lists empty, but the payloads survive to be reported, dying only in
the terminal transaction. Only once that marker is durable does the
driver kill its live effects — their process-local continuations die, so
reconciliation finds orphans and settles them synthetically under ids
already reserved. Cancellation is never un-requested, and a repeated
abort returns the same drained ids without writing. Reconciliation itself
reuses the ordinary machinery: a cancelled pending request settles as
aborted; a cancelled tool batch stages aborted synthetics for planned
calls and interrupted ones for pending calls, then materializes in source
order; anything else drains its accepted writes and takes the aborted
terminal transaction.

**Doorbells** are the only process messages in the design, and losing one
is harmless by construction. `Nudge` asks a strand to re-plan now, and
its loss costs latency alone: the periodic poll tick drives a pass anyway
and finds the durable work, and any commit racing the strand's own
commits surfaces as a stale expectation that forces a reload. The session
API exposes `_quietly` variants that commit without ringing, and the
doorbell tests use them — accept quietly, steer quietly, never nudge, and
the run still completes with the steer in context.

## The supervision tree

```
  SessionSupervisor              rest-for-one
    ├── 1. StrandRegistry        names plus live reaper generations
    ├── 2. StorageWriter         every commit, and every driver read
    ├── 3. strand factory        simple-one-for-one; ordinary strands
    ├── 4. subagent factory      simple-one-for-one; own tolerance
    └── 5. strand booter         lists strand.*, starts what is missing
```

Rest-for-one over those five is the whole recovery policy, and the order
*is* the blast radius, as `runtime/supervisor.gleam` builds it. A writer
crash restarts the writer and every child after it, because a strand
holding a subject to a dead writer has nothing to say — and the booter,
sitting last, repopulates the factories the restart just emptied. A crash
in one strand restarts only that strand, because each factory supervises its own
children simple-one-for-one. Every child registers under a process name
rather than a pid, so restarts keep them addressable; the registry sits
first precisely so those names outlive everything that uses them. It also
stores every still-live effect reaper per logical strand. A replacement
publishes its new reaper and waits for every predecessor to drain before
recovery dispatches, so a restart cannot overlap a replay with an effect that
has received a kill signal but has not yet exited.

The two factories are one restart budget each, and the split is what buys
the separation. `supervisor.start_strand` asks `Config.subagent` which
factory owns a name — afresh every time, so the answer survives a restart
with no state of its own — and the default says nobody is a subagent, the
runtime having no way to tell a model-spawned strand from an
operator-spawned one. Lineage is a layer up. Because the subagent factory
sits *after* the primary one, a model-spawned strand in a crash loop
restarts only itself and the booter: it cannot reboot the strand a human
is talking to, nor spend the restart budget that protects it.

The writer is the single committer the durability plane's one-writer rule
assumes, and the driver's reads route through it too. After each
successful commit it publishes a `Committed` event and then calls an
injected `after_commit` observer — production passes a no-op, the
interleave harness a bomb. For SQLite sessions it renews the writer lease
on a timer, and a lost renewal stops it abnormally so the tree reboots
through the open path, which re-acquires the lease or fails loudly.

A restarted strand nudges itself immediately, so recovery needs no
external input: **recovery is cold start is the first drive pass.** The
booter is what makes that pass cover *every* strand rather than `main`
alone — it lists the `strand.*` registers and starts a driver for each
one it finds, routing each to its factory, so a cold open, a writer
crash, and a booter crash all converge on "list the store, start what is
missing" (`supervisor.boot_strands`). What that pass does before planning
is validate. Every register decodes
through a total decoder — a function returning either a fully constructed
value or a structured corruption report, never crashing and never
half-succeeding — and the bounded checks that follow are decoders in the
same spirit: `op.meta`'s id must agree with `strand.state` and name this
strand; a `Tools` phase must find its batch's source entry, and that
entry must be an assistant message; an `AwaitingDeferred` phase must find
a deferred handle on its source entry. A failed check faults the strand
rather than guessing, and under a corrupt restore the strand faults on
every attempt until the supervisor's tolerance is exhausted and the tree
dies — visibly. The recovery test asserts that, and asserts that the
corrupt register was never quietly "repaired" behind the operator's back.

Closing a session is a controlled crash of the same shape: kill the tree,
then close the storage handle. Commits are atomic, so durable state stops
at a commit boundary; nothing terminal is written, and reopening recovers
the open operation.

## Classifying a settled response

One settled assistant message can mean six different things, and the
order in which you ask decides which. First match wins, and the order is
normative because reordering it changes behavior rather than style:

1. **cancelled control** — an abort is already durable, so the response
   settles as aborted whatever it says;
2. **overflow** — adapter-reported, matching a canonical message pattern,
   or a `length` stop whose output count is below the intended output
   limit persisted in the intent (the input, not the output, hit the
   window);
3. **deferred with a structurally valid handle** — suspend and poll;
4. **error** — including an invalid deferred handle, carrying the
   adapter's retryability judgment;
5. **tool use** — or any accepted response carrying tool calls, with
   `truncated` marking a genuine output-limit stop whose calls must be
   answered with synthetic truncation errors rather than executed;
6. **stop, or a genuine output-limit length** — the run may finish.

Ask about cancellation first and a cancelled run never diverts into a
compaction on its way out; ask about tool use before a genuine length
stop and a truncated response executes calls cut in half.

Two normalizations happen at commit, both deliberate: a cancelled
response commits as `aborted`, and an overflow-classified one as `error`,
so that context projection drops it by the ordinary error rule instead of
needing a special case. An `aborted` stop reason under running control is
unreachable by construction, so it is reported as corruption.

The one thing classification cannot read from the message is whether the
adapter judged an error retryable, because no field carries it. The
runtime encodes that judgment as `raw_stop_reason == "retryable"` and the
machine reads it back — a convention `docs/spec-gaps.md` records, along
with the rest of the interpretations this plane made.

## The interleave harness

The correctness claim is "kill the process at any instant and the session
resumes without repeating itself." The harness turns that into an
enumeration, using the writer's `after_commit` seam as its crash
scheduler. The seam runs after a commit is durable and published but
*before* the committer's reply is sent, so killing the writer there
produces precisely the state "commit N is durable, and the committer
never learned it" — a crash between two adjacent commits, scriptable at
every boundary.

Each of five scenarios runs once uninterrupted to fix its commit count
`C`, then once per `k` in `1..C` with the bomb armed at commit `k`. The
counts are deterministic and asserted, which is what makes the
enumeration meaningful — **42 crashed runs in all**:

| scenario | shape | `C` |
|---|---|---|
| simple | prompt → assistant → finish | 5 |
| tools | assistant → two tool calls → assistant → finish | 14 |
| steer | a steer drained at the first checkpoint | 6 |
| abort | abort while a `ReplayNever` tool is mid-flight | 9 |
| retry | retryable provider failure → retry wait → success | 8 |

Every crashed run must converge: the same terminal outcome kind; the same
final *projected* context, fingerprinted structurally by role, text, call
id, and stop kind rather than by minted ids or timestamps; the same
ledger total; no `ReplayNever` tool executed twice; and the placement
invariants at the terminal boundary — no operation-owned or pending
registers left, the strand idle, every tool call answered by exactly one
result entry. A run armed to crash must also have actually crashed: a
bomb that never fired would make the loop vacuous.

Two divergences are legitimate, and are encoded as allowances rather than
smoothed over. A `ReplayNever` call whose intent commit was the kill
boundary comes back with the synthetic interrupted result, so the tools
scenario compares projections under a rule that accepts an error result
for the same tool and call id. And an early abort legitimately skips
whole turns, so that scenario asserts only its outcome and the
invariants, exempt from the ledger check. Everywhere else the ledgers
match exactly, because synthetic settlements bill zero and a settled
commit is never re-billed.

The enumeration has one blind spot by construction: an effect whose
intent commit *is* the kill boundary never started, so commit-boundary
crashes never interrupt a genuinely running effect. The crash-mid-tool
reproduction covers that. It hangs a `ReplayNever` tool, kills the tree
while the call is in flight, and reboots with a tool script that would
now answer normally — so a completed result could only come from a
re-execution. None appears: the synthetic interrupted result is in the
tree with its warning, the run completes, and the invocation counter
(held by a recorder that outlives the tree) still reads one.

The enumeration's other limit is that someone had to write the list. Its
five scenarios never reach a deferred poll, a compaction, a structural
summary, or a navigation, and its steer is admitted before the run
starts, so a concurrent admission never races a live effect. The
**deterministic simulation runner** generates that list instead, from a
seed, and injects faults the enumeration has no vocabulary for — stale
commit refusals, lease theft, lost doorbells, starved effects, a tree
killed mid-flight. `docs/architecture/simulation.md` describes it; the
interleave harness remains as the fixed, readable enumeration underneath.

**Cold open** raises the same claim to a whole session on disk. Eleven
runs over a SQLite session — twenty-two assistant turns, a tool call in
every run — with the eleventh run's tool hung when the tree is killed.
Everything closes, releasing the writer lease, and the session reopens
from the database file alone under a new owner and a new runtime. The
restored strand resumes the crashed run and finishes it: the interrupted
call was not re-executed, its synthetic result is in the transcript, all
twenty-two assistant turns are present, and the placement invariants
hold.

## Where the code lives

| Path | What it holds |
|---|---|
| `machine/operation.gleam` | The operation state space: `Operation`, `OperationState`, phases, batches, structural work, terminal results. |
| `machine/planner.gleam` | `next_action` and the whole transition table: checkpoints, generation, tools, deferred polls, failure drain, reconciliation, structural work, terminal transactions. |
| `machine/classification.gleam` | `settle`, `classify`, and the normative order. |
| `machine/acceptance.gleam` | `accept_prompt`: normalization, validation, and the single acceptance transaction. |
| `machine/queue.gleam` | Steer/follow-up/write/next-run admission, queue cancellation, and the abort marker. |
| `machine/strand.gleam` | `StrandConfiguration` and `StrandState`. |
| `machine/codec.gleam` | Total JSON codecs for every orchestration register payload; `machine/internal/build.gleam` holds the shared write builders and register keys. |
| `runtime/strand_runtime.gleam` | The strand driver: the drive loop, key resolution, effect dispatch, restore validation. |
| `runtime/writer.gleam` | The StorageWriter: the single commit path, committed events, the `after_commit` seam, lease renewal. |
| `runtime/supervisor.gleam` | The rest-for-one session tree. |
| `runtime/api.gleam` | Open/recover, prompt, steer, follow-up, abort, close. |
| `runtime/effects.gleam` | The injected effect seam: provider, tools, hooks, clock, entropy, timers. |
| `session/session.gleam` | Session open/close, strand seeding, typed register access, context projection. |
| `runtime/test/support/harness.gleam` | The interleave harness: scenarios, the crash scheduler, fingerprints, convergence checks. |
| `conformance/src/conformance/simulation/` | The deterministic simulation runner: seeded scripts, fault schedules, logical time, the named checks. |

Each path is relative to its package's source root — `machine/planner.gleam`
is `packages/machine/src/machine/planner.gleam`. For intent and contracts,
`docs/loom-design.md` §3.2–3.3 and §4 cover the durable program counter,
the effect sandwich, and this plane's shape; `docs/loom-implementation-spec.md`
§1.3 and §3.1 hold the frozen machine interface and the normative recovery
procedure; `docs/spec-gaps.md` records where implementation refined the spec.
