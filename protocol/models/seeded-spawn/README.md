# Seeded spawn protocol model

A small [P](https://p-org.github.io/P/) model of a spawn that carries the parent's
workspace (`protocol-change/107-state-transport.md`, slices 4a to 4c), from the
parent's ask to the pull of the child's commits: the receiving orchestrator
holds the bundle, finds or makes the child's own delegate session, reads the
attach census, sends the bundle, applies it behind a fence, starts the child,
captures what the child committed and ends the session at the join, while the
parent's orchestrator resends, joins and makes the single ref for the commits.
It sits beside the state transfer model, which covers the bundle's pieces, and
the remote subagents model, which covers the spawn's admission. It is run by
`make model-check`.

The code is the specification. Where the proposal and the code differ, the model
follows the code. It is a separate model and not an extension of
`remote-subagents` because that model's subject is a call site's admission and
release across orchestrators, and none of its machines holds a workspace, a fence
or a landing; adding them would have changed every one of its cases.

## What is modelled

| Machine | Stands for |
|---|---|
| `Owner` (`PSrc/Owner.p`) | The parent's orchestrator: the stub, the drainer that resends `Spawn` and `Join`, and the single ref `refs/loom/children/<child>/<tip>` made from a finished child's commits. |
| `Orch` (`PSrc/Orch.p`) | The receiving orchestrator: `spawn_seed.land` with its verdict file, claim and census check, the child's delegate session, the Agency's spawn, and the join, which captures the child's commits and ends its session. |
| `Exec` (`PSrc/Exec.p`) | The executor's scope for the session: the attach (incarnation and token), the bundle store, the worktree's tip and the apply and capture behind the fence. |
| `Wire` (`PSrc/Wire.p`) | The two links, one between `Owner` and `Orch` and one between `Orch` and `Exec`. One queue per direction, delivered in any interleaving, lost whole when the link breaks. |
| `Chaos`, `Harness` (`PTst/Tests.p`) | The environment: dropped links, a restart of any of the three machines, an asker that gives up, a late bundle, and the child's work. When the faults are spent it pokes the owner on a quiet network until the owner is done. |

A state is a tip, an integer. The seed's tip is 1 and the child's work moves the
tree to 2, so an apply of 1 over a tree at 2 is an older tip over a newer one. The
executor records the tip it applied last and answers a request for it without
touching the tree. A
capture carries the size its description names and the size that arrived.

Both placements are modelled. `PL_EXEC` is a child on an executor or a pool, with
one delegate session for each child and the whole chain above. `PL_DIR` is a
child in a directory of the receiving orchestrator, whose copy is made under the
claim and kept, with the pair's session and no executor.

### The order of an ask

`Orch` answers a `Spawn` in the order of `spawn_seed.landed`.

| The receiver holds | It does |
|---|---|
| a verdict | answers it, and ends the child's session if one is left |
| a session that is open and resident | asks whether it has begun: a child that has is answered as it was, a record that cannot be read is a reason to ask again, and a fresh one falls through |
| the bundle not yet whole | answers ask again |
| otherwise | runs a pass under the claim: find or make the session, attach and read the census, send the bundle, ask again whether the session has begun, send the fenced apply, and then make the Agency's spawn |

A restart forgets the verdicts and the claims, because the daemon deletes
`seed-staging`, where it keeps both, when it starts. A transient failure (no room,
a fence that moved, an unanswered request, a record that could not be read) keeps
no verdict, lets go of the claim and leaves the session. A refusal the same inputs get again (a state the executor judges
malformed, a workspace that refuses it) keeps the verdict and ends the session in
a step of its own after the verdict is written. A census that says the workspace
takes no state ends the session at once and keeps no verdict. The Agency's spawn
is a step of its own after the apply is confirmed, so a restart can come between
them, and it is made only when the asker still waits.

### The join

`Orch` answers a `Join` for a child that has ended: it captures the child's
commits from the executor, checks that the bundle arrived whole and that this
node's store has room, keeps the settled answer, ends the child's session and
answers. A join asked again after that is answered from the kept answer, so the
session's absence does not refuse it. A join before the child has ended, or while
another is running, answers that the child is still finishing. A run end stops a
running child first and keeps its session, because a join can still bring the
commits back.

Nothing attaches the session again after the executor restarted, so a capture that
is refused as stale is refused every time it is asked. The same holds for a bundle
that arrives short and a store with no room. The return does not give up by count,
because what costs the tries is often an answer that is not about the commits, and
it does not wait for ever, because that would withhold the child's report. It is
bounded by time: once the window has passed (`eWindow`, the model's one event for
`spawn_return.give_up_s`, ten minutes, longer than an executor takes to restart and a
link to repair) the join gives up, settles the child with its report and no commits
and ends its session, and the notice says where the commits still are. A session
that an orchestrator restart closed is opened again by the next join, which attaches
it, and that is the only attach a join gets.

### One checkout at a time

`Exec` runs a checkout of a state for a scope in a step that takes some time, and
a second `StateApply` that arrives while it is running joins it and is answered
with its result. The orchestrator sends the apply again when the executor link is
repaired, which is how a second request reaches a checkout that is still going.

## What is checked

| Spec | Rule |
|---|---|
| `FirstTurnAfterSeed` | The child's first turn never runs before the seed is applied, in either placement, and the tree the seed is applied to is then on the parent's commit, even when the executor's workspace is ahead of it (`TestBehind`). |
| `AtMostOneSession` | At most one delegate session exists for the child, however asks, restarts and retries interleave. |
| `AppliedAtMostOnce` | The seed is applied to a scope at most once, however many apply requests are sent. |
| `NoOlderOverNewer` | A retry, or a request that arrives late, never applies an older tip over a newer one. This rests on the executor answering a tip it applied before without touching the tree. |
| `RefNamesOnlyDescribedCommits` | The owner's ref names only a bundle whose arrived size is the one its description names. |
| `NoPermanentVerdictFromTransient` | A verdict is kept only for a deterministic refusal. |
| `UnreadableIsNotBegun` | A session whose record could not be read is never taken for one that has begun. |
| `EverySpawnEnds` | Liveness: an asked spawn ends, started with the seed applied or refused for good. |
| `EverySettledChildIsReleased` | Liveness: a child whose verdict is kept or whose result is kept has its session released. |
| `JoinIsRepeatable` | A join asked again after the child settled and its session was released is not refused. |
| `OneRefPerChild` | The child's commits are made into one ref, not two. |
| `EveryFinishedWorkIsReturned` | Liveness: a child that settled with commits has them in the parent's repository, across a lost reply, a resend and an orchestrator restart. Finished work is returned unless the executor cannot answer within the window, and then the report is returned with the notice and no commits (`GivesUpOnlyAfterTheWindow`). |
| `GivesUpOnlyAfterTheWindow` | The return gives up on a child's commits only once the window has passed. |
| `NoReleaseWhileRunning` | A session is not released while its child runs. |
| `ResultKeptBeforeRelease` | A session is not released before the settled answer is kept. |
| `OneApplyAtATime` | An executor runs one checkout at a time for a scope. |
| `RunEndStopsTheChildren` | A run end stops the children whatever becomes of the pair's session. |

P reports a violation of a liveness spec when a run ends with its monitor in the
hot state, so each liveness spec holds only because every fault is bounded.

## What the model found

`EverySettledChildIsReleased` failed on a schedule that the code can produce, once
the model forgot verdicts at a restart as the code does (the daemon deletes
`seed-staging`, where it keeps them, when it starts). `placing` writes a refusal's
verdict, lets go of the claim, ends the child's session and only then answers the
asker. A second ask that arrives between the verdict and the end of the session finds
the verdict and was answered with it, and its owner stops asking. A restart before
the end of the session then lost the step that ends it and the verdict with it, and
the session stayed. The window is small and the cost is a session held until the
parent is deleted, and the code now ends the session when an ask finds a verdict
(`spawn_seed.landed`), which does nothing when the session is gone. Mutant M19
removes that and is caught. It does not cover a restart that comes before any second
ask, which forgets the verdict and is answered by the asker's own next ask, and it
does not cover a failure of the release itself, which the model does not have.

An earlier edition of this model kept the verdict across a restart and described a
leak that needed no second ask. That was an error in the model. The specs for the
join, the return, the release and the checkout were written from the two reviews of
the pull request, and each has a mutant that reintroduces the fault.

## Probes

The `tcProbe*` cases must fail: each finds a witness for a situation the specs are
only meaningful if the model reaches. They are an apply retried against a tree
that already held the seed, a restart between the confirmed apply and the spawn,
a capture served after the executor restarted, an apply refused as stale, a
refusal that kept a verdict, a ref made from a child's commits, an executor with
no room, a record that could not be read, a join answered from the kept answer, a
second apply that joined the first, a store with no room for the commits, and a run
end that stopped a running child.

## Mutants

`mutate.py` applies each mutant as exact text replacements, runs the test case
that names the rule, and requires the case to fail on that rule. `make
model-check` runs it. M6 to M8 are the two review findings of the pull request as
they stood before the fix: a transient executor failure recorded as a verdict, and
a record that cannot be read answered as a session that has begun.

| Mutant | Violates |
|---|---|
| The Agency's spawn is made before the apply is sent | `FirstTurnAfterSeed` |
| The session is created when it is not resident, not when it has no record | `AtMostOneSession` |
| The executor does not answer a tip it applied before without touching the tree | `NoOlderOverNewer` |
| A tree that is only a descendant of the parent's commit is taken for the parent's tree and not moved | `FirstTurnAfterSeed` |
| The executor counts a repeated apply as applying the seed again | `AppliedAtMostOnce` |
| Neither the join nor the owner compares a bundle's size with its description | `RefNamesOnlyDescribedCommits` |
| An executor with no room is kept as a verdict | `NoPermanentVerdictFromTransient` |
| A stale fence is kept as a verdict | `NoPermanentVerdictFromTransient` |
| A record that cannot be read answers that the session has begun | `UnreadableIsNotBegun` |
| The join, and a join asked again, do not end the session | `EverySettledChildIsReleased` |
| A refusal's session is not ended in the step after the verdict | `EverySettledChildIsReleased` |
| An ask that finds a verdict does not end the session | `EverySettledChildIsReleased` |
| A transient failure keeps the claim | `EverySpawnEnds` |
| A join asked again is refused because the answer was not kept | `JoinIsRepeatable` |
| A store with no room for the commits settles the child with nothing | `EveryFinishedWorkIsReturned` |
| The return gives up at the first failure and not after the window | `GivesUpOnlyAfterTheWindow` |
| A failure of the Agency's answer to a resend whose child began ends the session | `NoReleaseWhileRunning` |
| The owner makes the ref again for a repeated answer | `OneRefPerChild` |
| The join captures and ends the session of a child that is still running | `NoReleaseWhileRunning` |
| The session is ended before the settled answer is kept | `ResultKeptBeforeRelease` |
| A second apply runs a checkout of its own | `OneApplyAtATime` |
| The run end is handled behind the pair's session | `RunEndStopsTheChildren` |

## What the model leaves out

- **The bundle's pieces.** A send is one request the executor answers stored, no
  room or malformed. Resumption, repeats and gaps are the state transfer model's.
- **The census as its own step.** The attach and the census share the claim in the
  model. In the code the attach is part of finding or making the session and runs
  before the claim, so two asks may attach at once. An attach is idempotent on the
  executor, and the claim still admits one apply.
- **A second child, and a spawn asked for after the join.** The model has one
  child, and its owner does not send a spawn after the answer that carries the
  result. In the code such a spawn finds no verdict and no session and starts a
  second child that nothing joins. It is not modelled and not claimed.
- **The claim's staleness.** A restart clears the claim, which the code does too,
  by deleting `seed-staging` at start. A claim left by a process that died while
  the daemon stayed up is taken as stale after fifteen minutes in the code and
  never in the model.
- **The kept answer's content.** The answer is its tip and two sizes. That it is the
  settled entry in every field is tested in `joined_record_test`.
- **A child whose record cannot be read.** The model's owner knows where its child
  is. `child_join_test` and `spawn_return_test` cover a record that cannot be read.
- **Time.** An asker that gives up is an event, and no deadline is measured.
- **The untrusted link** of protocol-change 109 and 110. The state messages of a
  seeded spawn travel over it by the same path, untested, and the model says
  nothing about it.
- **The thin capture's content.** A capture is its tip and two sizes. That the
  commits are thin against the seed, and that the ref is made by `return_apply`,
  are tested against real repositories in `spawn_return_test`.
- **Usage, budgets and the tool ceiling.**

## Running it

From this directory, with the P tool installed
(`dotnet tool install --global P`):

    p compile
    p check -tc tcAllExec -s 1000
    p check -tc tcProbeApplyRetried -s 2000    # must find a bug
    python3 mutate.py --check

`make model-check` runs every case of every model, probes included, and the
mutants of the projects that have a `mutate.py`.
