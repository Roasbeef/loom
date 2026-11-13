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
tree to 2, so an apply of 1 over a tree at 2 is an older tip over a newer one. A
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

A transient failure (no room, a fence that moved, an unanswered request, a record
that could not be read) keeps no verdict, lets go of the claim and leaves the
session. A refusal the same inputs get again (a state the executor judges
malformed, a workspace that refuses it) keeps the verdict and ends the session in
a step of its own after the verdict is written. A census that says the workspace
takes no state ends the session at once and keeps no verdict. The Agency's spawn
is a step of its own after the apply is confirmed, so a restart can come between
them, and it is made only when the asker still waits.

## What is checked

| Spec | Rule |
|---|---|
| `FirstTurnAfterSeed` | The child's first turn never runs before the seed is applied, in either placement. |
| `AtMostOneSession` | At most one delegate session exists for the child, however asks, restarts and retries interleave. |
| `AppliedAtMostOnce` | The seed is applied to a scope at most once, however many apply requests are sent. |
| `NoOlderOverNewer` | A retry never applies an older tip over a newer one. The executor takes any tip, so this rests on the orchestrator's check that the session has not begun. |
| `RefNamesOnlyDescribedCommits` | The owner's ref names only a bundle whose arrived size is the one its description names. |
| `NoPermanentVerdictFromTransient` | A verdict is kept only for a deterministic refusal. |
| `UnreadableIsNotBegun` | A session whose record could not be read is never taken for one that has begun. |
| `EverySpawnEnds` | Liveness: an asked spawn ends, started with the seed applied or refused for good. |
| `EverySettledChildIsReleased` | Liveness: a child whose verdict is kept or whose result is stored has its session released. |

P reports a violation of a liveness spec when a run ends with its monitor in the
hot state, so each liveness spec holds only because every fault is bounded.

## What the model found

`EverySettledChildIsReleased` failed on the code as it stood. `placing` writes the
verdict, lets go of the claim and only then ends the child's session, and a
restart between the first and the last left a refused child with a session. A
later ask found the verdict and answered it without ending the session. The
session was bounded by the parent's release, which walks every session the pair
holds. The code now ends the session when an ask finds a verdict
(`spawn_seed.landed`), and the model does the same on the verdict branch of
`handleSpawn`. Mutant M9 removes that and is caught.

## Probes

The `tcProbe*` cases must fail: each finds a witness for a situation the specs are
only meaningful if the model reaches. They are an apply retried against a tree
that already held the seed, a restart between the confirmed apply and the spawn,
a capture served after the executor restarted, an apply refused as stale, a
refusal that kept a verdict, a ref made from a child's commits, an executor with
no room, and a record that could not be read.

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
| The session's begun check before the apply is removed | `NoOlderOverNewer` |
| The executor counts a repeated apply as applying the seed again | `AppliedAtMostOnce` |
| Neither the join nor the owner compares a bundle's size with its description | `RefNamesOnlyDescribedCommits` |
| An executor with no room is kept as a verdict | `NoPermanentVerdictFromTransient` |
| A stale fence is kept as a verdict | `NoPermanentVerdictFromTransient` |
| A record that cannot be read answers that the session has begun | `UnreadableIsNotBegun` |
| An ask that finds a verdict does not end the session a restart left | `EverySettledChildIsReleased` |
| A transient failure keeps the claim | `EverySpawnEnds` |

## What the model leaves out

- **The bundle's pieces.** A send is one request the executor answers stored, no
  room or malformed. Resumption, repeats and gaps are the state transfer model's.
- **The census as its own step.** The attach and the census share the claim in the
  model. In the code the attach is part of finding or making the session and runs
  before the claim, so two asks may attach at once. An attach is idempotent on the
  executor, and the claim still admits one apply.
- **A second child, and a spawn asked for after the join.** The model has one
  child. A resend of a spawn that arrives after the child was joined and its
  session ended would find no session and make one; the sender does not send it
  after the answer, and the model does not generate it. This is not checked and
  is not claimed.
- **The claim's staleness.** A restart clears the claim. In the code a claim left
  by a dead process is taken as stale after fifteen minutes.
- **Time.** An asker that gives up is an event, and no deadline is measured.
- **The untrusted link** of protocol-change 109 and 110. A seeded spawn over it is
  refused by the code, so the model has nothing to say about it.
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
