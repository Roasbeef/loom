# Deterministic simulation

The interleave harness proved a claim by enumeration: five scripted
scenarios, killed at every commit boundary, forty-two crashed runs, all
convergent. Enumeration is only ever as good as the list, and the list
was written by hand — so the deferred poll, the compaction, the
structural summary, and the navigation were never crash-tested at all,
and a steer could never race a live effect because every steer was
admitted before the run started. The simulation runner replaces the list
with a generator. One integer picks what the session is asked to do and
what goes wrong while it does it; the runner then holds the result to a
set of named checks, and prints the integer when one breaks.

## Seed, script, schedule, verdict

A run of the runner is four steps.

```
  seed ──split──▶ script      what the session is asked to do
       └─split──▶ schedule    what goes wrong while it does it

  script + no faults ──▶ the fault-free run
  script + schedule  ──▶ the faulted run
                         │
                         ▼
                     the checks
```

The split is the important half. A **script** is semantic: which
settlement each assistant turn produces, what each tool returns, whether
the context overflows or a threshold trips, when the user steers or
aborts, and which operations run on the strand. A **schedule** is a list
of faults, and every fault in the taxonomy is *transparent* by
definition — it must not change what the session ends up having done.
Anything that legitimately changes the outcome is in the script, so it
happens in the fault-free run too and cannot be mistaken for damage.
That is what makes "the same script converges to the same place under
every schedule" a claim worth checking rather than a tautology with
exceptions.

Both runs use the real supervision tree, the real writer, the real
strand driver, and the real machine over an in-memory session. Only the
effects are scripted, and only the storage record is wrapped.

## Keying, and why it is not a counter

A provider script that answered "the third request I see" would answer
differently after a crash, and the two runs would be comparing different
conversations. So nothing in a script is keyed by a counter.

A generation request is answered by the **phase** of its projected
context: how many assistant messages are in it, plus a hundred once a
compaction summary is. Errored, aborted, and deferred responses never
enter a projection, so a synthetic settlement written by recovery leaves
the phase where it was — which is exactly the property that makes phase
a stable key. A tool execution is answered by its scripted call id, and
call ids are unique within a script. Interventions name durable
positions too (`during turn 2`, `during call t00write`, `at the terminal
commit`), never dispatch ordinals, and each fires once per session under
a claim held by a process outside the tree.

Interventions triggered at the terminal commit are the one case that
fires from inside the writer rather than from an effect, and they are
never waited for: admission calls back into that same writer, so
awaiting one deadlocks it. Only cancellation is generated there.
A steer or follow-up at that boundary fires after the terminal
transaction is already durable, so the operation it would attach to no
longer exists and admission can only be refused — and firing
asynchronously, in a script with a second operation, it could attach to
that one instead, which is a race with no property behind it. The DSL
still expresses it, and the pinned corpus uses it, because the runner
must stay correct under it; the generator does not draw it.

A `during turn`/`during call` intervention is live-triggered from
*inside* an effect, but no longer *fires* from one. The effect that
reaches the trigger only asks whether the script has anything due there
and, if it does, registers the trigger with the control actor and
blocks; the runner's own drive loop drains that queue on every pass and
performs the admission itself, then releases the effect. The block is
what still makes the steer land before the settlement that follows it —
the effect does not resume until the runner reports the admission
durable — but the process actually carrying the admission is now the
runner's, never the effect's. That distinction is the whole fix: the
runner is never a target of any fault in the taxonomy, so a
`RestartStrand` that reaps the effect waiting on the release cannot take
the admission down with it (see "What this does not cover" below for
what this closed).

Faults may use ordinals, because a fault need not mean the same thing
twice — only the outcome must. Commit-indexed faults name a global
commit ordinal counted across writer restarts, so "kill after commit 7"
survives the tree rebooting; effect-indexed faults name a dispatch
ordinal counted the same way.

## Simulated time

Nothing in a simulated session sleeps to make time pass. One logical
clock is shared by everything that reads time — the storage backend's
commit timestamps, the strand driver, the effect scripts, id minting —
so the eras that drift apart when two components carry separate real
clocks cannot drift here. The clock moves only when the runner moves it,
and it moves in one step: to the earliest registered deadline.

Deadlines come from a seam added to the effect record for this:

```gleam
pub type Timers {
  Timers(after: fn(Int, fn() -> Nil) -> Nil)
}
```

`effects.real_timers()` waits on a short-lived process and is what
production wiring passes; the simulation's implementation files the
deadline in the clock's wheel instead. The strand driver's two delayed
wakeups — the checkpoint poll and the retry wait — go through it. A
dropped wake costs liveness only: every deadline the driver sets is a
hint, and the durable state it re-reads on the next pass decides what
actually happens. Firing one early is equally safe, which is what lets
the runner treat quiescence as permission to advance.

Quiescence is observed, not computed. The runner subscribes to the
writer's committed events; while they arrive, the session is working and
time stands still. When a millisecond passes with none, either the
session is waiting for a deadline or it is inside an effect, and
advancing the clock releases the first and costs the second one wasted
planning pass.

Finishing is observed the same way, and needs one more condition. A
commit is durable — and its terminal result readable — *before* the
writer runs the post-commit seam that a crash schedule fires from, so a
runner that took the terminal result the moment it appeared could end a
run while the fault armed on its last commit was still queued. The
runner therefore waits for the seam to close before accepting a terminal
result. A crash closes the killed writer's seam, while every recovered
writer must close each new seam it opens. That is what keeps a
commit-indexed fault's chance to fire part of the run rather than a race
against the observer.

Two wall-clock waits are left in a simulated session, and both are named
where they live. The first is the provider surface's own settlement
timeout, which only a scripted timeout fault reaches. The second is
`control.attempt`'s budget, which is how anything reaches into a tree
that may be mid-restart; it is documented as **not simulation-safe** in
its own doc comment and is discussed under "What this does not cover"
below. Neither is part of a seed.

## The fault taxonomy

| Fault | What it does | What it must not change |
|---|---|---|
| `CrashAtCommit(n)` | Kills the writer after commit `n` is durable and published, before its committer learns of it | anything |
| `CrashDuringEffect(n)` | Kills the writer — and with it, rest-for-one, the strand — while dispatch `n` is running | anything |
| `RefuseCommitStale(n)` | Refuses commit `n` as a stale expectation without applying it, as a concurrent admission would | anything |
| `ReadFault(n)` | Faults the next store read after commit `n` | anything |
| `StealLease(n)` | Fails the writer's next lease renewal after commit `n`, once | anything |
| `DropDoorbell(n)` | Loses doorbell `n` entirely | anything (the checkpoint poll finds the work) |
| `DelayDoorbell(n, ms)` | Delivers doorbell `n` after `ms` of logical time | anything |
| `SlowEffect(n, ms)` | Effect `n` settles only after `ms` of logical time | anything |
| `ProviderEffectDies(n)` | Provider effect `n`'s process dies without settling | anything |
| `ProviderEffectTimesOut(n)` | Provider effect `n` never settles; the surface's timeout settles it in band | anything |

Two of these are bounded by the shape of the system rather than by
taste. **Effect loss** — the last two rows — is transparent only where a
retry ladder stands behind it, so the schedule skips it on a deferred
poll: pi §3.2 gives every poll error a response-provenance failure
drain, with no retry, so losing one is a semantic change and belongs in
a script if it belongs anywhere. And the run's retry ladder is
deliberately generous (six attempts against a backoff the clock skips),
because a schedule must not be able to turn a completed run into a
failed one by arithmetic on the attempt count.

Crash faults are capped at one per schedule. Two nested tree kills tell
no story the single kills do not, and they multiply run time.

Wire faults are a separate property over the effect plane's framing,
driven by the same generator: a stream of well-formed frames torn at
arbitrary boundaries must decode to exactly the frames it was built
from; a stream with a byte flipped in it must report a fault or decode
to something well formed, and a deframer that has faulted must stay
faulted; a stream cut short mid-frame must deliver what completed and
carry the rest. No helper process is involved — generated bytes are
faster and reach cases a cooperating helper never would.

## The checks

Each check has a name, and a failure reports it.

| Check | Claim |
|---|---|
| `run/terminated` | Both runs reached a terminal result |
| `run/crash-fired` | A commit-indexed crash the faulted run reached actually fired |
| `invariant/boundary` | At every commit boundary, a queued id has its pending register, or its entry, or neither — never both |
| `terminal/registers` | No operation-owned or pending register survives a terminal transaction, and the strand is idle |
| `tree/calls-answered` | Every tool call in the tree has exactly one result entry |
| `terminal/last-result-once` | `strand.last_result` was written once per operation |
| `replay/never-once` | No `replay: Never` call was executed twice |
| `convergence/outcome` | The faulted run's operations ended the same way the fault-free run's did |
| `convergence/projection` | The final projected transcripts match |
| `convergence/ledger` | The usage totals match |

The placement invariant is checked *inside* the commit path, so a
violation is reported at the transaction that caused it rather than at
the end of the run. The rest are checked once the strand is idle again.

Two divergences are allowed, and both are encoded rather than smoothed
over. A `replay: Never` call interrupted in flight comes back as the
synthetic interrupted result for the same tool and call id, so the
projection comparison accepts an error result there. And a script that
aborts is a race by design — how far the run got before the marker
landed is not a property of the fault schedule — so an aborting script
is held to the per-run checks and to nothing about convergence.

## What the generator reaches

The suite asserts its own coverage: every run reports the named paths it
reached, and the sweep fails if the union misses any of them. The four
recovery paths review finding ORCH-H1 named as untested are in that list
— `deferred-poll`, `threshold-compaction` and `overflow-compaction`,
`structural-generated` with its nested `summary-request`, and
`navigation-summarized` — as are the two interleavings the same finding
said the harness structurally could not reach:
`steer-during-effect`, where the steer commits from inside the live
assistant effect so the settlement that follows loses its seq race by
construction, and `abort-at-terminal-commit`, where the abort is sent
from the writer after the terminal transaction is durable and before its
committer learns of it.

Reaching them needs hooks that do something. The runtime's default hooks
decline every structural decision and never cross a threshold, which is
precisely why the enumerated harness never reached compaction; the
simulation's hooks trip the threshold from the durable projection (so
the decision is the same after a crash as before it), supply or generate
summaries, and prepare overflow compactions. Compaction and navigation
have no api entry point yet, so the runner builds their acceptance the
way `runtime/api` builds a run's and commits it through the same writer.

## Reproducing a failure

A failing seed prints its check, then two lines about the failure rather
than about the property, then the reproduction line:

```
convergence/projection — fault-free [...] but faulted [...]
    [timing] HARNESS LOST A SCRIPTED TURN: faulted run:
      intervening@follow-up-during-effect — ...
    [verdict] NOT REPRODUCIBLE — this seed was run 2 times and failed 1. ...
seed 317  |  script: run(defer>overflow) then navigate | no threshold |
generated/split | abort@turn0  |  faults: crash@c1 + readfault@c3 + dropbell@1
```

The two annotations exist so that a red soak does not have to be
re-litigated by hand. `[timing]` is what the run observed about its own
conduct — whether a real millisecond budget expired in it, whether any
reply went unobserved, and whether a scripted intervention was claimed
and never seen to land. `[verdict]` is stronger and costs re-runs: the
same seed is replanned (the same script, the same schedule — `plan` draws
only from the seed) and run again up to three times, and the failure is
reported as `REPRODUCIBLE` only if every one of them failed too.

`NOT REPRODUCIBLE` does not mean "nothing is wrong". A genuine race in
the code under test is unreproducible too. What it means is that this one
red run does not distinguish a diff from the commit before it, so the
thing to compare is the failure *rate* over many runs of the seed — and a
seed that was stable before a change and unstable after it is a finding,
because becoming unstable is a behaviour change. Shrinking is skipped for
an unreproducible failure: "does this smaller schedule still fail?" is
answered by coin toss there, and a minimal schedule arrived at that way
would be a fiction.

The seed alone re-runs the case. The script and fault summaries are
there so the shape of the failure is legible without re-running it, and
so a failure that no longer reproduces can still be recognized.

The soak entry point corroborates first and shrinks second. On failure it
re-runs the case with candidate simpler schedules — drop one fault, or pull one
fault's index toward the start of the run — and keeps the smallest that
*still fails*. Nothing is inferred: a reported minimal schedule is one
that was observed to fail, so the worst shrinking can do is fail to
shrink.

The shrinker has been exercised against the defect it was built for: with
the orphaned-poll fix reverted, a three-fault schedule reduces to the one
fault that still fails.

Scripts are not shrunk. A script's meaning depends on its whole shape
(a turn's settlement is chosen by the phase its predecessors produced),
so dropping a turn produces a different session rather than a simpler
one, and a "minimal script" arrived at that way would be a fiction.

## Running it

`make check-conformance` runs the fast sweep — forty-eight generated
seeds in three chunks, the coverage assertion over the same seeds, four
hundred wire seeds, and the pinned corpus — in about twenty seconds.

`make soak` runs the long one: `SOAK_SEEDS` seeds (default 2000) from
`SOAK_FROM` (default 1), with shrinking. Budget roughly a second per
seed. It is opt-in through the environment rather than a separate
target's worth of machinery, so `LOOM_SOAK_SEEDS=500 gleam test` inside
`packages/conformance` does the same thing — with one caveat that the
target handles for you.

The test framework imposes a per-test timeout of about a minute, and it
reports a run that exceeds it as a timeout rather than as a result. Since
per-seed cost varies, a single invocation asking for more than a few
dozen seeds can trip it and look like a hang in whatever the runner
happened to be doing. `make soak` therefore runs in chunks of
`SOAK_CHUNK` seeds (default 50), advancing the starting seed and stopping
at the first chunk that fails, which is why the seed range is echoed
before each one. Driving the environment variables directly means
choosing a count that fits inside the timeout yourself.

A soak failure prints the same reproduction line as any other. Re-run
that seed alone through the fast path first: if it reproduces, the
schedule is deterministic and the failing check names the property to
read. If it does not, the failure depends on an interleaving the runner
does not control (see below), and the seed is a hint rather than a
handle — run the soak again over a range containing it and see whether
it returns.

The pinned corpus is the memory. A case that found a real defect is kept
as a hand-built script-and-schedule pair rather than as a seed, because
a seed's meaning changes the moment the generator does, and a regression
test that quietly stops testing the regression is worse than none.

## What this does not cover

**Message interleaving is not controlled.** The runner is deterministic
about *decisions* — which commit is killed, which effects fail, in what
order, what each turn settles with — and reproduces them exactly from a
seed. It does not reproduce the BEAM's scheduling of independent
processes, because it drives real processes rather than a simulated
scheduler. Two runs of one seed can therefore interleave differently and
must both converge; that is the property being checked, but it also
means a failure that depends on a rare interleaving may not reproduce on
demand. A true reproducible-interleaving simulator needs the whole
runtime to run on an injected scheduler, which is a larger change than
this.

What *is* controlled is how such a failure reads. Every failure carries
the `[timing]` and `[verdict]` annotations described under "Reproducing a
failure", so an unreproducible one says so in its own output instead of
looking exactly like a behaviour difference. That distinction is the
point: the expensive failure mode is not the flake, it is a real
regression waved away as "the box was busy".

**`control.attempt` still holds a real millisecond budget.** Reaching
into a session tree that may be mid-restart is done on a disposable
process, and waiting for that process is bounded by real time, not
logical time. It cannot be made logical: the action blocks on a real OTP
call, the logical clock moves only when the runner moves it, and the
runner is the process doing the waiting — a logical deadline would have
nobody left to fire it. So the budget stays, demoted to a **deadlock
backstop**: a bound that stops a wedged call hanging a CI job, not a
bound anything is expected to reach.

What used to reach it routinely was the disposable process *dying*, which
is the ordinary outcome when the writer it is calling is killed
mid-commit. That is now observed through a process monitor and reported
at once as `Raised`, so it costs no wall-clock time and happens at the
same point in the run on an idle box and a loaded one. The budget expiring
is a separate outcome, `Expired`; every occurrence is recorded and named
in the failure the run reports, so a seed that touched the wall clock says
which call site did it. Neither outcome is treated as proof that the
action failed — an admission whose reply was lost may already be durable,
and the retry paths ask the durable state rather than assuming (this is
the same ambiguity the steer-drop work records).

**A scripted intervention's loss used to be silent sometimes, and no
longer is — though the loss itself is not yet closed.** An intervention
claims a one-shot and then admits; the admission ran on a disposable
process spawned *from the effect that reached the live trigger*, so the
effect process awaiting it could be reaped by a `RestartStrand` fault
before `control.attempt`'s own `record_attempt` ever ran — meaning some
of these losses carried no `raised@`/`expired@` tag at all, only the bare
`intervening@path` the dangling check still caught. That gap is closed:
a live trigger now only registers itself and blocks (see "Keying, and
why it is not a counter" above), and the runner's own drive loop — never
a target of any fault in the taxonomy — is what performs the admission,
enforces its budget, and therefore always survives to record what
happened to it. Measured on seed 53 (twelve fault-free/faulted pairs
against pristine `main`, then the same twelve against this change): the
baseline showed both shapes — a `raised@intervene` next to the dangling
entry on some runs, and on others an `intervening@` with no
`raised@`/`expired@`/`intervened@` at all, the silent case. Every
faulted run under this change carried the explicit tag.

What this does not do is stop the intervention from being lost. The
carrier the runner now owns can still find *its own target* mid-restart
— the strand it is admitting into, not the effect that triggered it —
and a name the tree has not yet re-registered still raises. That race is
about timing between the runner's drive pass and the target strand's own
recovery, not about which process survives, so moving the caller does
not touch it: `convergence/projection` still fails on seed 53 at
essentially the same rate observed before this change (measured, not
assumed — both twelve-run samples above landed close to the seed's
long-documented ~40%). Retrying the admission after a `Raised` would
close it for the cases where nothing actually committed, but not safely:
`perform`'s own comment already warns that firing a claimed intervention
twice makes a different session than the fault-free one, and unlike
`admit`'s retry — which asks durable state whether its accept already
landed before trying again — there is no equivalent durable check here
for "did this specific steer already land". Building one is a real next
step, but a different one from this issue, which was to move the
*decision* to the runner; it does not, by itself, make every retry safe.
The bracketing (`intervening@path` / `intervened@path`) and the `HARNESS
LOST A SCRIPTED TURN` report stay in place regardless, because a future
change could still find a way to leave a claim dangling, and a run that
did should still say so rather than reporting an unexplained divergence.

**The `terminal/last-result-once` counter is fenced across commit
visibility** (issue #58). The missing write was in the harness's side
counter, not in the machine's terminal transaction. The memory actor
installed the transaction and replied before `store.commit_and_check`
called `control.note_commit` and bumped `last_result:*`. The runner reads
the unwrapped memory store, so under load it could observe the durable
operation result while the control actor still said that the seam was
quiet, accept the terminal, and snapshot the old counter. The same
ordering explains why added logging suppressed the failure and why
dedicated reruns rarely reached it.

The instrumented store now opens a synchronous accounting fence before
calling the inner commit. A successful commit atomically hands that fence
to the post-commit seam, so `seam_quiet` stays false until its counters and
boundary checks are recorded; a failed commit releases the fence without
opening a seam. The writer's existing seam remains responsible for the
scheduled fault that runs after a successful commit.
`simulation_store_test` probes from inside the
inner wrapper immediately after the raw commit becomes visible, where the
old ordering deterministically reported quiet, and checks both the success
and error paths. This leaves the production terminal transaction unchanged
and keeps the exact once oracle intact.

**One backend, one strand, one session.** Every simulated session is an
in-memory store with a synthetic lease. The SQLite backend's own
crash behaviour is the storage conformance suite's subject, and the cold
open test is what proves a session reopens from a file. Multi-strand
interleaving does not exist yet.

**No real effect plane.** The provider, the tools, and the hooks are
scripted; the broker, the helper, and the sandbox are not in the loop.
The jailed end-to-end suite covers that seam, and the wire property
covers the framing between them, but a simulated session never executes
anything.

**Scripts are shallow in one direction.** A generated script has one run
operation followed by at most one standalone compaction or navigation,
at most one deferred turn, and at most three assistant turns. Longer
sessions are reachable by widening the generator, and the cost is run
time, not correctness.

**The clock is not adversarial.** Time moves forward, one deadline at a
time. Clock skew between components is impossible here by construction
rather than tested, and a clock that jumps backwards is not simulated.

## Where the code lives

| Path | What it holds |
|---|---|
| `conformance/simulation/random.gleam` | The splittable SplitMix64 generator every choice is drawn from |
| `conformance/simulation/vclock.gleam` | The logical clock and its timer wheel |
| `conformance/simulation/script.gleam` | The operation DSL and its generator |
| `conformance/simulation/fault.gleam` | The fault taxonomy, schedule generation, and shrinking |
| `conformance/simulation/control.gleam` | The counters, one-shot claims, and runtime handle that outlive the tree |
| `conformance/simulation/store.gleam` | The instrumented session: commit counting, stale refusals, read faults, the stealable lease |
| `conformance/simulation/surface.gleam` | The scripted provider, tools, and hooks |
| `conformance/simulation/invariant.gleam` | The named per-run checks |
| `conformance/simulation/runner.gleam` | Seed to verdict: execute, compare, shrink, report |
| `conformance/simulation/wire.gleam` | The framing properties |
| `conformance/test/conformance/simulation_test.gleam` | The fast sweep, the coverage assertion, the pinned corpus, the soak gate |

Each path is relative to its package's source root. The plane these
tests are pointed at is described in `docs/architecture/orchestration.md`;
`docs/review/orchestration.md` finding H1 is what they were built to
close.
