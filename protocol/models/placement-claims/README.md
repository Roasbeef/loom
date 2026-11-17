# Pool placement claims model

This directory holds two models of a pool. `Claims.tla`, below, is how first
opens spread over the pool's executors. `Admission.tla`, in the last part of this
file, is how one seeded child is admitted while every executor is full.

`Claims.tla` is a [TLA+](https://lamport.azurewebsites.net/tla/tla.html) model of
how an orchestrator spreads the first opens of sessions over the executors of a
pool (PR #1185). The change merged without a model. `make model-check` checks it
with the mutants listed below.

A session created in a pool names a workspace that every executor of the pool
registers, and the orchestrator picks the executor when the session first opens.
`pools.spread` (`client/pools.gleam`) orders the pool's candidates by how many
open scopes this orchestrator has already placed on each, fewest first, and the
configured position breaks a tie. A session that is still being built holds no
open scope yet, so the registry keeps a claim for it (`Book.claims` in
`client/daemon/manager.gleam`). `manager.claim_placement` counts, orders and
records the head of the order as the session's claim. A claim counts while the
session's slot is waiting or building (`live_claims`), and stops counting when the
slot is running, when the open scope counts instead, or when the builder fails or
the slot is gone. The builder tells the registry which executor took its scope
(`seed_executor`), which points the claim there.

The model checks the design and the code's shape, not the contents of any
executor. It has no load, no capacity, and no other orchestrator's sessions.

## What is modelled

`NExec` executors in a configured order and `NSess` sessions that each open once
and may retry. The state is:

| Variable | Meaning |
|---|---|
| `ph` | A session's phase: `new`, `snapped`, `read`, `building`, `running` or `failed`. `building` is a slot that is waiting or building. |
| `claims` | `Book.claims`: the executor each session last claimed, or none. |
| `ord` | The order the registry answered a session with. |
| `att`, `reg` | The executor on which a session's scope is open, and the executor the catalogue says it is placed on. |
| `snap` | The set of sessions that were resident when a session's open read the catalogue. |
| `retries`, `restarts` | Retries of a failed open, and restarts of the registry, both bounded. |
| `removed` | History: a built session failed, or the registry restarted. |
| `viol` | History: an ask counted a session other than exactly once. |

| Action | What it is |
|---|---|
| `Snap(x)` | The caller of `claim_placement` reads the resident counts from the catalogue, as the code did before the read moved into the turn (the removed `ledger_holdings.resident_by_name`). Skipped when `AtomicRead`. |
| `Turn(x)` | The registry's turn: the resident counts plus one for each other session whose claim `live_claims` keeps, ordered by `pools.spread`. With `OneTurn` it records the head as the claim in the same step. |
| `Record(x)` | The record of the choice, as a separate step, for the mutant without `OneTurn`. |
| `Attach(x, i)` | The builder's scope opens on the `i`-th candidate, after the first `i - 1` declined. Only the executors of `Down` decline. The claim and the catalogue row point at the executor that took it. |
| `Finish(x)` | The slot becomes running: the claim stops counting and the catalogue row counts. |
| `Fail(x)` | The builder fails before the slot is running, and its scope closes. |
| `Retry(x)` | A failed open is asked for again. The old claim entry stays until the next turn replaces it. |
| `Restart` | The registry restarts: its memory, the claims included, is lost with every slot. Sessions are saved again, their scopes close, and opens are asked for again. |

### What differed between the code and its description

`claim_placement`'s doc comment says the counts, the order and the record are one
turn of the registry. Until `distributed/claims-read-in-turn` they were not,
for the open scopes. The caller evaluated
`ledger_holdings.resident_by_name(directory, roster.fixed(rows))` before it
called the registry (`daemon/main.gleam`, the `claim` closure in the pool
branch), and passed the result as an argument. That function read the catalogue
a page at a time, each page and each read of custody being a registry turn of
its own, and counted the sessions whose slot was running. Only the claims were
read inside the turn that followed. `AtomicRead = FALSE` is that shape, and
`ClaimsMutantReadOutsideTurn.cfg` is the code before that change.
`AtomicRead = TRUE` counts the open scopes in the same turn as the claims, which
is what the description says, and it is the clean configuration and the code
now: the registry reads its own rows in the turn (`manager.placed_rows`) and
hands them to a pure function (`ledger_holdings.resident_in`).

### What is abstracted away

- A session opens once, with its retries. A session that closes after it ran is
  not modelled, so `Balanced` is stated for runs in which nothing was removed.
- A registry restart is a daemon restart: the registry's own death leaves the
  daemon recovery-blocked, so every slot and every claim is gone. Sessions then
  open again. The model does not tell a restart of the registry from a restart
  of the daemon.
- The executors' own counts, and the other orchestrators', do not take part. The
  count is this orchestrator's bookkeeping, as the doc comment of `pools.spread`
  says.
- A failed claim call is not modelled. The registry that does not answer in five
  seconds leaves the session unclaimed, and `claim_placement` then orders by the
  resident counts alone. That is the same ordering as the `TwoTurns` mutant,
  and it fails `Balanced` the same way.
- Executors that are down are the set `Down`. They decline every attach for the
  whole run. A session that no candidate takes cannot finish, so liveness is
  checked with `Down = {}`.
- The sessions are interchangeable, so `OpensSettle` is stated for session 1.

## Properties

`Occupancy(e)` is what the registry's count of `e` should be: the running
sessions placed on `e`, and the building sessions whose claim names `e`.
`Perceived(e)` is what an ask would count now with the read made now.

| Property | Statement |
|---|---|
| `Balanced` | When nothing has failed and the registry has not restarted, the claims plus open scopes on any two executors that take attaches differ by at most `Bound`. |
| `ClaimCountedOnce` | Each time an open asks, every other session that holds an executor or is about to is counted exactly once, by its resident row or by its claim. Never both, and never neither. |
| `NoLeakedClaim` | No executor is counted as holding more than it holds: `Perceived(e) <= Occupancy(e)`. A builder that failed, a slot that is running, and a registry that restarted leave no claim that counts. |
| `OpensSettle` | An open that is asked for comes to run or to fail, under weak fairness of the read, the turn, the record, the attach and the finish. Failures, retries and restarts are not fair. |

### The bound `Balanced` guarantees

The code guarantees `Bound = 1`, and only when both of these hold. The opens
count each session exactly once, which needs the open scopes read in the
registry's turn. And each attach lands on the executor that the order named
first. TLC checks that bound over three executors and four concurrent opens, and
over three executors, three sessions, one retry and one restart.

When an attach is declined, the claim of a session that is still building names
the declining executor, so another ask sees that executor as busy and the
declined session, which lands on the next candidate, was not counted there. With
one executor of three declining every attach, `Bound = 1` is violated in 23
states, and `Bound = 2` holds for three sessions and for four. With the old
read there was no bound: four sessions can all land on one executor, so a bound
of three is violated.

## Running it

```sh
java -cp ~/tools/tla2tools.jar tlc2.TLC -workers 1 -config protocol/models/placement-claims/Claims.cfg protocol/models/placement-claims/Claims.tla
```

or `make model-check`, which also runs every mutant. The gate finds the mutants
by the name `ClaimsMutant*.cfg`.

## Results

On TLC 2.19, one worker, two executors and three sessions for the clean run, and
two of each for the mutants:

| Configuration | Outcome | States generated | Distinct | Depth |
|---|---|---|---|---|
| `Claims.cfg` | no error, `OpensSettle` holds | 334,442 | 98,434 | 21 |
| `ClaimsMutantReadOutsideTurn.cfg` | `ClaimCountedOnce` violated | 64 | 49 | 7 |
| `ClaimsMutantTwoTurns.cfg` | `Balanced` violated | 24 | 21 | 5 |
| `ClaimsMutantCountsRunning.cfg` | `ClaimCountedOnce` violated | 40 | 34 | 5 |
| `ClaimsMutantFailureKeeps.cfg` | `NoLeakedClaim` violated | 4 | 4 | 3 |

`Claims.cfg` has one retry and one restart. A run outside the gate over three
executors and three sessions, with the same retry and restart and safety
properties only, found no error in 2,261,792 states generated, 695,839 distinct.
The bound scans in the previous section are runs of the same model with one
property and the constants stated there.

Reachability was checked by hand with throwaway invariants that TLC must
violate: a builder that fails; a failed session asked for again while its old
entry stays; a session running after a restart; two sessions on different
executors; two building sessions with claims on different executors, so that
claims make opens see each other; a session placed on the second executor; a
running session while another failed. Dropping weak fairness of `Finish`, of
`Turn` or of `Attach` makes `OpensSettle` fail, so the liveness check is not
vacuous.

## Mutation checks

| Mutation | Constant | Counterexample |
|---|---|---|
| The open scopes are read before the turn | `AtomicRead = FALSE` | The code before the change that reads them in the turn. Session 2 reads the catalogue while session 1 is building. Session 1 attaches and becomes running, so its claim stops counting. Session 2's turn then counts neither the claim nor, in the read it made earlier, the running row. It picks the executor that session 1 holds, and both sessions are on it. `ClaimCountedOnce` breaks, and `Balanced` with it. |
| The count and the record are separate steps | `OneTurn = FALSE` | Two opens read the same counts, and both pick the first executor before either records. This is the burst race the PR fixed, and the registry's five-second fallback has the same effect. `Balanced` breaks. |
| A claim keeps counting once its slot is running | `CountsRunning = TRUE` | The session is counted as a claim and as an open scope. `ClaimCountedOnce` breaks. |
| A claim is not released when its builder fails | `FailureKeeps = TRUE` | The failed session keeps counting toward its executor. `NoLeakedClaim` breaks. |

To add a mutation, add a `ClaimsMutant<Name>.cfg` with an `expect-violation`
line. The gate discovers it without an edit to the script.

## Finding: the open scopes were read before the registry's turn

`ClaimCountedOnce` did not hold of the code that merged with #1185, because the
resident counts were read by the caller before `claim_placement`'s turn. The
trace from `ClaimsMutantReadOutsideTurn.cfg`, seven states long, with the code
behind each step:

1. Session 1 reads the resident counts (`ledger_holdings.resident_by_name`):
   none. Its turn (`ClaimPlacement` in `client/daemon/manager.gleam`) records a
   claim on the first executor.
2. Session 2 reads the resident counts: none, since session 1 is not running.
3. Session 1's builder attaches (`seed_executor`) and its slot becomes running.
4. Session 2's turn runs. `live_claims` drops session 1's claim, because its slot
   is running and no longer waiting or building. The resident counts that session
   2 passes in were read before step 3 and do not hold session 1. `held_by` adds
   nothing for it.
5. The first executor counts zero, ties with the others on count, and wins on
   position. Both sessions are on it.

The window was the time between a caller's read of the catalogue and its turn,
and a session's build had to finish inside it. It was narrow on an idle daemon
and wider on a busy one, because a turn waits behind every message queued before
it, and it matters for a burst of opens such as eight children on eight machines.

The fix is the one the model checks as clean. `resident_by_name` called the
registry (`manager.page` and `manager.custodies`), so it could not run inside a
turn, and it is removed. The registry instead reads the registrations, their statuses and move rows
itself in the turn, and `ledger_holdings.resident_in` turns those rows into the
same counts with no call. `placement_claim_test` has a test in which a session
that became resident is counted once, by its row, and one that reads the counts
before the turn, which reproduces the old placement.

# Admission of a seeded child on a full pool

`Admission.tla` is the receiving orchestrator's admission of one seeded child
(protocol-change/107, slice 4b) while every executor of the pool is at its scope
limit, written after the second drive of issue #1137's exit criterion 3
(2026-11-16). Its table and rules are in protocol-change/107, addendum of
2026-11-17. `make model-check` checks it with the mutants below.

## What is modelled

Two askers ask for the same child, as the code does: the spawn tool
(`agency.ask_until_answered`) and the session's drain (`remote_drain.spawn_pass`).
The orchestrator port serves each ask in a process of its own, so every registry
turn and every read of one ask can fall between two steps of the other.

| Variable | Meaning |
|---|---|
| `row` | The child's delegate row: none, open or releasing. |
| `sid`, `regs`, `reg` | The registration the row names, every registration that exists for the child, and the named one's state (reserved or saved). |
| `kept` | The start failure the catalogue kept: none, no room, or lost (the write failed). |
| `slot` | The registry's slot: none, building, closing or running. |
| `room`, `finished` | A scope is free; another child of the parent has finished and holds its scope until a join collects it. |
| `ask`, `held` | Each asker's step (idle, polling, about to end the row, done) and the registration it was admitted to. |
| `stub`, `dpass`, `silent` | The parent's stub; where the drain's pass is; whether its spawn step marked the box silent. |
| `started`, `final`, `made` | History: the registrations a child was started in; whether any asker was answered a final refusal; registrations made. |

| Action | What it is |
|---|---|
| `Admit(a)` | The registry's turn of an ask (`manager.delegate_now`): create, refuse a releasing row, admit a building slot, answer a closing one, or, for a reserved row with no slot, build it again (R1) or do what the code of e128668ee did. |
| `Read(a)` | One read of an admitted ask's poll (`delegate_host.resident`). A registration that is gone is a final store failure. |
| `End(a)` | The end by name that followed a no-room poll before R1. |
| `BuildEnds`, `Retire` | The build succeeds with a free scope and fails for no room without one; the failed slot drains. |
| `SkipSpawn`, `Join` | The drain's pass after its spawn step: the join frees a finished child's scope unless the box was marked silent. |
| `Finish` | Another child finishes. |

The parent's own `agent_wait` is not modelled: it runs only after the spawn tool
returns, and the properties are about the asks. The poll's 20 second bound is not
modelled; a read is strongly fair instead, because a poll reads every 200 ms and
the other asker's rebuilds can make the slot building again between two of its
reads.

| Constant | Rule |
|---|---|
| `RetryInPlace` | R1: a repeat ask builds the reservation again; nothing ends a row for no room. |
| `BareAsksAgain` | R2: a reservation with no kept failure asks again. |
| `AnswerNotSilent` | R3: NotYetOpen does not mark the box silent for the drain's join. |
| `FinalReleases` | A final refusal ends the child's session (`spawn_seed.ended_unless_asks_again`). |
| `RetryMakesNew` | Mutant of R1: the repeat ask makes a new reservation. |
| `LostFailure` | The catalogue may fail to keep a start failure, once. |

## Properties

| Property | Statement |
|---|---|
| `NoRoomNeverFinal` (P1) | Every build fails only for want of room, so no asker is answered a final refusal. |
| `PlacedOnceRoomFrees` (P2) | With both askers asking and another child finishing, the child is placed and the stub learns its handle. |
| `OneSessionPerChild` (P3) | At most one registration exists for the child, and a child is started in at most one. |
| `NothingHeldUnplaced` (P4) | Once the parent has stopped asking with the child unplaced and no ask is in flight, no row, registration or slot is left. |

## Results

On TLC 2.19, one worker:

| Configuration | Outcome | States generated | Distinct |
|---|---|---|---|
| `Admission.cfg` | no error, `PlacedOnceRoomFrees` holds | 240 | 89 |
| `AdmissionMutantToday.cfg` | `NoRoomNeverFinal` violated, six states | 77 | 43 |
| `AdmissionMutantEndsOnNoRoom.cfg` | `NoRoomNeverFinal` violated | 77 | 44 |
| `AdmissionMutantBareIsFinal.cfg` | `NoRoomNeverFinal` violated | 72 | 42 |
| `AdmissionMutantNotYetOpenSilences.cfg` | `PlacedOnceRoomFrees` violated | 96 | 34 |
| `AdmissionMutantRetryMakesNew.cfg` | `OneSessionPerChild` violated | 41 | 25 |
| `AdmissionMutantFinalKeepsRow.cfg` | `NothingHeldUnplaced` violated | 411 | 196 |

`AdmissionMutantToday.cfg` is the code the drive ran, all three rules off. Its
trace is run D5: the tool's ask makes the reservation and polls it; the build
fails for no room and the slot drains; the drain's ask reads the kept failure
and ends the row (`reserved_refusal`); the tool's next read finds the
registration gone, which the sender takes as final.

| Mutant | Rule it removes | Violates |
|---|---|---|
| `AdmissionMutantEndsOnNoRoom` | R1 | `NoRoomNeverFinal` |
| `AdmissionMutantBareIsFinal` | R2 | `NoRoomNeverFinal` |
| `AdmissionMutantNotYetOpenSilences` | R3 (runs D3 and D6) | `PlacedOnceRoomFrees` |
| `AdmissionMutantRetryMakesNew` | R1 done by a new reservation | `OneSessionPerChild` |
| `AdmissionMutantFinalKeepsRow` | the end of a refused child's session | `NothingHeldUnplaced` |

## What it leaves out

One child and one other child that finishes; one free scope once it is joined;
no restart of either daemon; no release of the parent (a release that crosses an
ask in flight is an older question and is not claimed here); no build failure
other than no room; the seed's transfer and apply, which are the seeded spawn
P model's.

## Running it

```sh
java -cp ~/tools/tla2tools.jar tlc2.TLC -workers 1 -config protocol/models/placement-claims/Admission.cfg protocol/models/placement-claims/Admission.tla
```
