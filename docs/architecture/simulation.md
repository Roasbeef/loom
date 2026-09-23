# Deterministic simulation

The simulation runner is a randomized crash and fault tester for the
orchestration plane. From one integer seed it generates a **script** (what
the session is asked to do) and a **schedule** (what goes wrong while it
does it). It runs the script twice over the real supervision tree, once
without faults and once with the schedule, holds the results to a set of
named checks, and prints the seed when one breaks.

The runner replaced the interleave harness, which proved convergence by
enumeration: five scripted scenarios, killed at every commit boundary,
forty-two crashed runs, all convergent. That list was written by hand. As
a result, the deferred poll, compaction, the structural summary, and
navigation were never crash-tested at all, and a steer could never race a
live effect because every steer was admitted before the run started. The
runner replaces the hand-written list with a generator.

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

The split between script and schedule is what makes the checks
meaningful. A script is semantic: which settlement each assistant turn
produces, what each tool returns, whether the context overflows or a
threshold trips, when the user steers or aborts, and which operations run
on the strand. A schedule is a list of faults, and every fault in the
taxonomy is *transparent* by definition: it must not change what the
session ends up having done. Anything that legitimately changes the
outcome belongs in the script, so it happens in the fault-free run too and
cannot be mistaken for damage. That is why "the same script converges to
the same place under every schedule" is a claim worth checking rather than
a tautology with exceptions.

Both runs use the real supervision tree, the real writer, the real strand
driver, and the real machine over an in-memory session. Only the effects
are scripted, and only the storage record is wrapped.

## Keying, and why it is not a counter

Nothing in a script is keyed by a counter. A provider script that answered
"the third request I see" would answer differently after a crash, and the
two runs would be comparing different conversations.

Instead, each scripted response is keyed by a durable position:

- A generation request is answered by the **phase** of its projected
  context: how many assistant messages it contains, plus a hundred once it
  contains a compaction summary. Errored, aborted, and deferred responses
  never enter a projection, so a synthetic settlement written by recovery
  leaves the phase unchanged. That property is what makes phase a stable
  key.
- A tool execution is answered by its scripted call id, and call ids are
  unique within a script.
- Interventions name durable positions too (`during turn 2`, `during call
  t00write`, `at the terminal commit`), never dispatch ordinals. Each
  fires once per session, under a claim held by a process outside the
  tree.

Interventions triggered at the terminal commit are the one case that fires
from inside the writer rather than from an effect. They are never waited
for, because admission calls back into that same writer and awaiting one
would deadlock it. Only cancellation is generated there. A steer or
follow-up at that boundary fires after the terminal transaction is already
durable, so the operation it would attach to no longer exists and
admission can only be refused. Because it fires asynchronously, in a
script with a second operation it could also attach to that operation
instead, which is a race with no property behind it. The DSL still
expresses such an intervention, and the pinned corpus uses it, because the
runner must stay correct under it; the generator does not draw it.

A `during turn` or `during call` intervention is triggered live from
inside an effect, but it no longer fires from one:

1. The effect that reaches the trigger asks whether the script has
   anything due there.
2. If it does, the effect registers the trigger with the control actor and
   blocks.
3. The runner's drive loop drains that queue on every pass and performs
   the admission itself.
4. The runner releases the effect once it reports the admission durable.

The block still makes the steer land before the settlement that follows
it. The process that carries the admission, however, is now the runner's,
never the effect's. That is the fix: no fault in the taxonomy targets the
runner, so a `RestartStrand` that reaps the effect waiting on the release
cannot take the admission down with it (see "What this does not cover"
below for what this closed).

Faults, unlike scripts, may use ordinals, because a fault need not mean
the same thing twice; only the outcome must stay the same.
Commit-indexed faults name a global commit ordinal counted across writer
restarts, so "kill after commit 7" survives the tree rebooting.
Effect-indexed faults name a dispatch ordinal counted the same way.

## Simulated time

Nothing in a simulated session sleeps to make time pass. One logical
clock is shared by everything that reads time: the storage backend's
commit timestamps, the strand driver, the effect scripts, and id minting.
Components therefore cannot drift apart the way they do when each carries
its own real clock. The clock moves only when the runner moves it, and it
moves in one step, to the earliest registered deadline.

Deadlines come from a seam added to the effect record for this purpose:

```gleam
pub type Timers {
  Timers(after: fn(Int, fn() -> Nil) -> Nil)
}
```

`effects.real_timers()` waits on a short-lived process and is what
production wiring passes. The simulation's implementation files the
deadline in the clock's timer wheel instead. The strand driver's two
delayed wakeups, the checkpoint poll and the retry wait, go through this
seam. A dropped wake costs liveness only: every deadline the driver sets
is a hint, and the durable state it re-reads on the next pass determines
what actually happens. Firing a wake early is equally safe, which is what
lets the runner treat quiescence as permission to advance the clock.

Quiescence is observed, not computed. The runner subscribes to the
writer's committed events, and while they arrive the session is working
and the clock stays put. When a millisecond passes with no event, the
session is either waiting for a deadline or inside an effect. Advancing
the clock releases the first and costs the second one wasted planning
pass.

The stall allowance measures consecutive silence, not the lifetime of an
operation. Every committed event replenishes it. Charging commits against
the same allowance would let a healthy multi-commit run exhaust the budget
while making durable progress, so Linux scheduler load would produce
intermittent `run/terminated` failures that pass on immediate replay.

The runner detects that a run has finished the same way, with one extra
condition: it waits for the post-commit seam to close before accepting a
terminal result. A commit is durable, and its terminal result readable,
*before* the writer runs the post-commit seam that a crash schedule fires
from. A runner that took the terminal result the moment it appeared could
therefore end a run while the fault armed on its last commit was still
queued. A crash closes the killed writer's seam, and every recovered
writer must close each new seam it opens. Waiting for the seam keeps a
commit-indexed fault's chance to fire inside the run rather than in a race
against the observer.

Two wall-clock waits remain in a simulated session, and both are named
where they live. The first is the provider surface's own settlement
timeout, which only a scripted timeout fault reaches. The second is
`control.attempt`'s budget, which bounds every call into a tree that may
be mid-restart. Its own doc comment marks it **not simulation-safe**, and
"What this does not cover" below discusses it. Neither wait is part of a
seed.

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

Two limits on the taxonomy follow from the system's structure rather than
from preference. First, effect loss (the last two rows) is transparent
only where a retry ladder stands behind it, so the schedule skips it on a
deferred poll. pi §3.2 gives every poll error a response-provenance
failure drain, with no retry, so losing a poll is a semantic change and
belongs in a script if it belongs anywhere. Second, the run's retry ladder
is deliberately generous (six attempts against a backoff the clock skips),
so that a schedule cannot turn a completed run into a failed one by
exhausting the attempt count.

Crash faults are capped at one per schedule. Two nested tree kills
exercise nothing that single kills do not, and they multiply run time.

Wire faults are a separate property over the effect plane's framing,
driven by the same generator. Three claims are checked:

- A stream of well-formed frames torn at arbitrary boundaries must decode
  to exactly the frames it was built from.
- A stream with a byte flipped must report a fault or decode to something
  well formed, and a deframer that has faulted must stay faulted.
- A stream cut short mid-frame must deliver the frames that completed and
  carry the rest.

No helper process is involved. Generated bytes are faster and reach cases
a cooperating helper never would.

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

The placement invariant (`invariant/boundary`) is checked *inside* the
commit path, so a violation is reported at the transaction that caused it
rather than at the end of the run. The other checks run once the strand is
idle again.

Two divergences are allowed, and both are encoded in the checks. First, a
`replay: Never` call interrupted in flight comes back as the synthetic
interrupted result for the same tool and call id, so the projection
comparison accepts an error result there. Second, a script that aborts is
a race by design: how far the run got before the abort marker landed is
not a property of the fault schedule. An aborting script is therefore held
to the per-run checks and to nothing about convergence.

Several interventions may share one logical trigger. Queue admissions keep
their script order, and all of them commit before an abort from that same
moment is sent. Without that ordering in the harness, the abort cast raced
the synchronous admission after it, so whether the fault-free script still
had an active run depended on the host scheduler: seed 584 answered
differently on Linux and macOS. The runtime's abort race still exists
after the admission boundary. The rule only gives the comparison oracle
one baseline transcript.

## What the generator reaches

The suite asserts its own coverage. Every run reports the named paths it
reached, and the sweep fails if the union misses any of them. The list
includes the four recovery paths that review finding ORCH-H1 named as
untested:

- `deferred-poll`
- `threshold-compaction` and `overflow-compaction`
- `structural-generated`, with its nested `summary-request`
- `navigation-summarized`

It also includes the two interleavings the same finding said the old
harness structurally could not reach:

- `steer-during-effect`, where the steer commits from inside the live
  assistant effect, so the settlement that follows loses its seq race by
  construction.
- `abort-at-terminal-commit`, where the abort is sent from the writer
  after the terminal transaction is durable and before its committer
  learns of it.

Reaching these paths requires hooks that act. The runtime's default hooks
decline every structural decision and never cross a threshold, which is
why the enumerated harness never reached compaction. The simulation's
hooks trip the threshold from the durable projection (so the decision is
the same after a crash as before it), supply or generate summaries, and
prepare overflow compactions. Compaction and navigation have no api entry
point yet, so the runner builds their acceptance the way `runtime/api`
builds a run's and commits it through the same writer.

## Reproducing a failure

A failing seed prints its check, then two annotation lines about how the
run behaved, then the reproduction line:

```
convergence/projection — fault-free [...] but faulted [...]
    [timing] HARNESS LOST A SCRIPTED TURN: faulted run:
      intervening@follow-up-during-effect — ...
    [verdict] NOT REPRODUCIBLE — this seed was run 2 times and failed 1. ...
seed 317  |  script: run(defer>overflow) then navigate | no threshold |
generated/split | abort@turn0  |  faults: crash@c1 + readfault@c3 + dropbell@1
```

The two annotations let a red soak be triaged from its output instead of
by hand. `[timing]` records what the run observed about its own conduct:
whether a real millisecond budget expired, whether any reply went
unobserved, and whether a scripted intervention was claimed and never seen
to land. `[verdict]` is stronger and costs re-runs. The runner replans the
same seed (the same script and schedule, since `plan` draws only from the
seed) and runs it again up to three times. It reports the failure as
`REPRODUCIBLE` only if every re-run failed too.

`NOT REPRODUCIBLE` does not mean nothing is wrong, since a genuine race in
the code under test is unreproducible too. It means this one red run
cannot distinguish a diff from the commit before it. The thing to compare
is the failure *rate* over many runs of the seed. A seed that was stable
before a change and unstable after it is a finding, because becoming
unstable is a behaviour change.

The seed alone re-runs the case. The script and fault summaries make the
shape of the failure legible without a re-run, and they let a failure
that no longer reproduces still be recognized.

The soak entry point corroborates first and shrinks second. On a
reproducible failure it re-runs the case with simpler candidate schedules
(drop one fault, or pull one fault's index toward the start of the run)
and keeps the smallest one that *still fails*. Nothing is inferred: a
reported minimal schedule is one that was observed to fail, so the worst
shrinking can do is fail to shrink. The shrinker has been exercised
against the defect it was built for: with the orphaned-poll fix reverted,
a three-fault schedule reduces to the one fault that still fails.

Two things are never shrunk:

- An unreproducible failure. Whether a smaller schedule still fails would
  be decided by chance, so a minimal schedule found that way would not be
  a real minimal failing case.
- Scripts. A script's meaning depends on its whole shape, since a turn's
  settlement is chosen by the phase its predecessors produced. Dropping a
  turn produces a different session rather than a simpler one, so a
  "minimal script" found that way would not be a real minimal case either.

## Running it

`make check-conformance` runs the fast sweep in about twenty seconds:
forty-eight generated seeds in three chunks, the coverage assertion over
the same seeds, four hundred wire seeds, and the pinned corpus.

Replay one generated session case with `make replay-simulation
SIM_SEED=33`. The target selects only `simulation_test:soak_test`, runs
exactly that seed, and prints the runner's full failure report before
failing. It does not run the fast sweep, the pinned corpus, or unrelated
jailed conformance tests. Repeat the same command to compare verdicts for
the same script and fault schedule; BEAM process interleavings remain
outside the seed's control.

`make soak` runs the long sweep: `SOAK_SEEDS` seeds (default 2000) from
`SOAK_FROM` (default 1), with shrinking. Budget roughly a second per seed.
The soak is enabled through the environment rather than through a
separate target, so `LOOM_SOAK_SEEDS=500 gleam test` inside
`packages/conformance` does the same thing, with one caveat that the
target handles for you.

The caveat is the test framework's per-test timeout of about a minute. A
run that exceeds it is reported as a timeout rather than as a result.
Because per-seed cost varies, a single invocation of more than a few dozen
seeds can trip the timeout and look like a hang in whatever the runner
happened to be doing. `make soak` therefore runs in chunks of `SOAK_CHUNK`
seeds (default 50). It advances the starting seed and stops at the first
chunk that fails, which is why it echoes the seed range before each chunk.
Driving the environment variables directly means choosing a count that
fits inside the timeout yourself.

A soak failure prints the same reproduction line as any other. Re-run
that seed alone with `make replay-simulation SIM_SEED=<seed>`; the failing
check names the property to read. Repeated failures strengthen the
evidence, but they do not establish control over BEAM scheduling. If the
failure does not repeat, an interleaving or another execution condition
outside the seed may be involved (see below). Keep the seed and compare
repeated runs before widening the range.

The pinned corpus keeps past defects under test. A case that found a real
defect is kept as a hand-built script-and-schedule pair rather than as a
seed, because a seed's meaning changes the moment the generator does. A
regression test that silently stops testing its regression is worse than
none.

## The daemon script

A second script runs above the session one, over a real daemon root, a
real registry and a real SQLite catalogue on a temporary state root
(`conformance/simulation/daemon/`). It draws one or two workspaces, one to
three creation keys, and the retries of those keys. Its faults kill the
whole daemon at a named creation step and restart it over the same state
root.

It checks four properties: `creation/one-identity-per-key`,
`creation/no-orphan-file`, `publication/before-execute` and
`replay/equal-catalogue-rows`. Together they require that a creation key
reserves one identity however the kill lands, that a conversation database
never exists without a confirmed catalogue row naming it, and that no
durable record predates its instance's publication.

For every drawn seed, the soak runs three scenarios: creation-key,
lifecycle, and domain retirement. Lifecycle covers restart and
revocation. Domain retirement compares an open after complete domain
cleanup with an open acknowledged while the original cleanup callback is
held. The seed varies which saved session reopens and how many duplicate
opens arrive. Both runs must preserve the accepted operation, avoid
replacement before cleanup release, and converge on the same catalogue
rows and revision after retirement.

The domain hold uses the assembly callback boundary and the real custody
owner. A one-shot claim in the existing simulation control actor selects
the workspace's first retirement; later cleanup proceeds normally. Failure
cleanup disarms a hold not yet reached, or releases the one already
waiting, before stopping the root. No production pause hook or separate
soak loop is added.

The daemon script does not cover kernel enforcement, resource
measurement, or the native TUI drivers, and it cannot. Kernel enforcement
is a claim about what bubblewrap and Seatbelt refuse. Resource measurement
is a magnitude under real load, which a logical clock deliberately does
not spend. The TUI drivers are two real terminal loops over real sockets.
Those stay with `loom-exec --self-test`, `make soak-daemon`, and
`tui_shipped_multiplayer_test`. The two-principal ordering scenario was
dropped rather than deferred: there is one gateway actor per resident
session, and the property it would have checked is already
`gateway_test`'s. The design note's amendments of 2026-09-08 carry the
argument and the kill model in full.

`make check-conformance` runs a small pinned corpus of daemon seeds.
`make soak-daemon-sim` runs the long sweep, bounded by
`SOAK_DAEMON_BUDGET_SECONDS` (default 120) rather than by a seed count. A
daemon seed's cost depends on the machine's file system and on whether
the schedule drew a kill, so a seed count buys an unpredictable amount of
lane time. The whole budget is spent in one run, which prints how many
seeds it drew and where a reader resuming the range by hand should start.

## What this does not cover

**Message interleaving is not controlled.** The runner is deterministic
about *decisions* (which commit is killed, which effects fail, in what
order, what each turn settles with) and reproduces them exactly from a
seed. It does not reproduce the BEAM's scheduling of independent
processes, because it drives real processes rather than a simulated
scheduler. Two runs of one seed can therefore interleave differently, and
both must converge; that is the property being checked. It also means a
failure that depends on a rare interleaving may not reproduce on demand.
A simulator with reproducible interleaving would need the whole runtime to
run on an injected scheduler, which is a larger change than this one.

What *is* controlled is how such a failure reads. Every failure carries
the `[timing]` and `[verdict]` annotations described under "Reproducing a
failure", so an unreproducible failure says so in its own output instead
of looking exactly like a behaviour difference. The costly mistake the
annotations guard against is not tolerating a flake; it is dismissing a
real regression as "the box was busy".

**`control.attempt` still holds a real millisecond budget.** Calls into a
session tree that may be mid-restart run on a disposable process, and
waiting for that process is bounded by real time, not logical time. The
bound cannot be logical: the action blocks on a real OTP call, the logical
clock moves only when the runner moves it, and the runner is the process
doing the waiting, so a logical deadline could never fire. The budget
therefore stays as a **deadlock backstop**: a bound that stops a wedged
call from hanging a CI job, not one anything is expected to reach.

What used to reach the budget routinely was the disposable process
*dying*, the ordinary outcome when the writer it is calling is killed
mid-commit. A process monitor now observes that death and reports it at
once as `Raised`, so it costs no wall-clock time and happens at the same
point in the run on an idle box and a loaded one. The budget expiring is a
separate outcome, `Expired`. Every occurrence is recorded and named in the
run's failure report, so a seed that touched the wall clock says which
call site did it. Neither outcome is treated as proof that the action
failed. An admission whose reply was lost may already be durable, and the
retry paths query the durable state rather than assuming (the same
ambiguity the steer-drop work records).

**A scripted intervention survives both sides of a lost reply.** A live
trigger registers with the control actor and blocks. The runner's own
drive loop, which no simulated fault can reap, takes the decision and
performs the admission. The wait has no separate wall-clock escape,
because it carries the scripted payload rather than a doorbell. Letting
the effect continue while the payload remained queued would permit a steer
or follow-up to land after the settlement it must precede.

The runner's carrier can still lose a synchronous writer call while the
tree restarts. That outcome is ambiguous by itself: the transaction may be
absent, or it may be durable with only its reply lost. The runner resolves
the ambiguity durably:

1. Each simulated intervention carries a deterministic identity in the
   opaque signature of its user-text block.
2. The instrumented store recognizes that identity and appends a reserved
   write-once fact, guarded absent, to the pending-entry transaction.
3. After a carrier dies, the runner reads that fact straight from the raw
   durable session. A present fact settles the intervention as landed; an
   absent fact permits another carrier.

No post-commit observation stands between the durable write and recovery.
Concurrent old and new carriers cannot double-admit, because only one
transaction can satisfy the fact's absent expectation.

The `intervening@path` / `intervened@path` bracket remains. It is no
longer the expected explanation for seeds such as 33 or 53. It now guards
against any future path that spends the in-memory one-shot claim without
making the correlated payload durable. A run that trips it still reports
`HARNESS LOST A SCRIPTED TURN` rather than passing harness damage off as a
convergence finding.

**The `terminal/last-result-once` counter is fenced across commit
visibility** (issue #58). The missing write was in the harness's side
counter, not in the machine's terminal transaction. The memory actor
installed the transaction and replied before `store.commit_and_check`
called `control.note_commit` and bumped `last_result:*`. The runner reads
the unwrapped memory store, so under load it could observe the durable
operation result while the control actor still reported the seam quiet,
accept the terminal, and snapshot the old counter. The same ordering
explains why added logging suppressed the failure and why dedicated
reruns rarely reached it.

The instrumented store now opens a synchronous accounting fence before
calling the inner commit. A successful commit atomically hands that fence
to the post-commit seam, so `seam_quiet` stays false until its counters
and boundary checks are recorded. A failed commit releases the fence
without opening a seam. The writer's existing seam remains responsible for
the scheduled fault that runs after a successful commit.
`simulation_store_test` probes from inside the inner wrapper immediately
after the raw commit becomes visible, where the old ordering
deterministically reported quiet, and checks both the success and error
paths. The fix leaves the production terminal transaction unchanged and
keeps the exact once oracle intact.

**One backend, one strand, one session.** Every simulated session is an
in-memory store with a synthetic lease. The SQLite backend's own crash
behaviour is the storage conformance suite's subject, and the cold open
test proves a session reopens from a file. Multi-strand interleaving does
not exist yet.

**No real effect plane.** The provider, the tools, and the hooks are
scripted; the broker, the helper, and the sandbox are not in the loop. The
jailed end-to-end suite covers that seam, and the wire property covers the
framing between them, but a simulated session never executes anything.

**Scripts are shallow in one direction.** A generated script has one run
operation followed by at most one standalone compaction or navigation, at
most one deferred turn, and at most three assistant turns. Widening the
generator reaches longer sessions, at a cost in run time, not correctness.

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

Each path is relative to its package's source root. The plane these tests
exercise is described in `docs/architecture/orchestration.md`;
`docs/review/orchestration.md` finding H1 is what they were built to
close.
