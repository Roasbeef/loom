# Session move protocol models

Two [TLA+](https://lamport.azurewebsites.net/tla/tla.html) specifications live
here. `Move.tla` is the move where each orchestrator's catalogue row decides
who owns the session, which every deployment without a `[directory]` runs.
`KhepriMove.tla` is the same move, and a move back, where the session
directory's owner record decides (protocol-change/079); it is described in
the last part of this file. `make model-check` checks both.

`Move.tla` is a model of one
controlled move of a session from one orchestrator to another. It is the
formal model for phase 5 of issue #697. The model exists because the move
is a sequence of local writes on two machines, with a crash possible between
any two of them, and the protocol claims that no interleaving leaves two
orchestrators serving the session or leaves the session without a complete
owner. TLC checks that claim over every interleaving of a small instance.

The model checks the protocol, not the code. It has no copy contents, no
directory lookups (phase 3), and no second move. The tests that run the
shipped code are the fixtures listed in the phase 5 design.

## What is modelled

One move with two orchestrator nodes, A the source and B the target, and one
executor between them. The state is:

| Variable | Meaning |
|---|---|
| `a` | A's catalogue row for the session: `active`, `moving` or `moved`. |
| `b` | B's catalogue row: `absent` or `active`. |
| `copy` | The transfer file: `none`, `cut` (on A) or `sent` (on B). |
| `exec` | The executor ledger row, `[inc, holder]`. A holder of `none` is a closed or never-attached scope. |
| `mover` | A's in-memory mover task: `idle` or `run`. |
| `servingA`, `servingB` | The node has a runtime serving the session. |
| `aliveA`, `aliveB` | The node's process is up. |
| `replied` | A holds B's reply to `Activate`. |
| `everMoved` | History: A has retired the session. |
| `crashes` | Crashes so far, bounded by `MaxCrashes`. |

`mover` and `crashes` are the two variables beyond the design's list. `mover`
is needed because the first mutation removes the durable `moving` row, and
what that row protects is the restart of a mover that has no memory of the
move. `crashes` bounds the environment so that the liveness property is
meaningful.

### Actions

| Action | Step of the protocol |
|---|---|
| `Intend` | 1. A writes `moving` and starts the mover. |
| `StopA` | 1 and 2. The slot stops and A closes the executor scope cleanly (`holder` becomes `none`). |
| `Cut` | 3. The consistent copy is cut. It needs the stop done and the scope closed. |
| `Send` | 4. The whole file is on B. |
| `Activate` | 5. B's row goes from `absent` to `active`, which needs `copy = sent`. |
| `LoseReply` | The reply to `Activate` is dropped. |
| `Retire` | 6. A writes `moved`. It needs to have observed B's row active, by the reply or by a status query to a live B. |
| `AbortEarly` | The way back before the send, `moving` to `active`. It needs `copy # sent`. |
| `RefuseActivate` | B's definitive refusal of an activation. A abandons the move, `moving` to `active`. B refuses only while its row is `absent`, and the copy it deletes with the refusal is gone. |
| `AttachExec(n)`, `OpenA`, `OpenB` | A node attaches to the executor, then starts serving. |
| `CrashA`, `CrashB`, `Restart` | A crash clears memory and keeps rows. A restart of A respawns the mover only for a `moving` row. |

`AttachExec` is the executor ledger's rule, `attach_existing` in
`packages/storage/src/storage/exec_ledger.gleam`. An open scope accepts a
claim of its own incarnation and rebinds the token to the claimant, whoever
held it. A closed scope accepts only incarnation + 1 and reopens at that
number. A node's claim comes from its cached cell, which can be stale, so the
model lets each node claim either number and lets the ledger decide. The
"rebind whoever held it" arm is what the executor fence alone does not
prevent, and why the catalogue rows, not the ledger, are the authority.

### What is abstracted away

- A scope that closes with `UnknownCleanup` refuses the move before any
  send. The model assumes the clean close: `StopA` always succeeds.
- B's definitive `Refused` is one action, `RefuseActivate`, and it stands for
  every refusal the receiver can send: a missing executor configuration, a
  scope that is not cleanly closed, a session held under another state. The
  model does not tell them apart. A bad digest or a missing copy is not an
  abort in the code (the source sends the file again, once), and is not
  modelled. The rule `RefuseUncommitted` says B never refuses once its row is
  `active`; the code holds it by answering a repeat of a committed activation
  from the row before it looks at anything else.
- Messages are not duplicated or reordered. `Activate` is one step, and the
  retries of an activation, which the code answers again from the row,
  collapse into it. A refusal of a retry is therefore a `RefuseActivate` from
  a state with `b = active`, which is what the mutant allows. `Send` does not
  need `aliveB`: the pieces are acknowledged one by one in the code, and a
  dead receiver makes the send stall until it is up. The model lets the copy
  arrive while B is down. That cannot produce two owners, because B's row
  stays `absent` until `Activate`, which needs B up.
- The file is cut and sent whole. A partial copy and the re-send are one
  step each.
- Incarnations are bounded by `MaxInc` and the first attach is a reopen from
  incarnation 0.
- Deadlock checking is off. The terminal states (`moved` with B serving, no
  crash left) have no enabled action.

## Properties

| Property | Statement |
|---|---|
| `OneOwner` | `~(servingA /\ servingB)`. |
| `NoResurrection` | `everMoved => a = moved`. No action leaves `moved`. |
| `ActiveImpliesComplete` | `b = active => copy = sent`, and `a = moved => b = active`. B's row is active only over the complete copy, and A retires only over an active B, so there is no state with a moved session and no complete owner. |
| `OneServingHolder` | `servingA => holder # B`, and `servingB => holder # A`. A node that serves holds the executor token. The design states the A half. |
| `MoveSettles` | `a = moving ~> a \in {moved, active}`, under weak fairness of `StopA`, `Cut`, `Send`, `Activate`, `Retire` and `Restart`. `RefuseActivate` is not fair: the move must settle without it. |

The second conjunct of `ActiveImpliesComplete` is an addition to the design's
statement. Without it, retiring early (the third mutation below) would leave
every listed invariant true, because the early retire loses the session
rather than duplicating it.

## Running it

TLC needs `tla2tools.jar` and a Java 11 or later. The gate looks for the jar
at `$TLA2TOOLS`, then `~/tools/tla2tools.jar`, and for Java at `$TLA_JAVA`,
then `java` on `PATH`, then a Homebrew `openjdk`. To run the clean
configuration alone:

```sh
java -cp ~/tools/tla2tools.jar tlc2.TLC -workers 1 -config protocol/models/session-move/Move.cfg protocol/models/session-move/Move.tla
```

Success is `Model checking completed. No error has been found.`

To run the clean configuration and every mutation, as the repository gate
does:

```sh
make model-check
```

Success is an `ok` line for `Move` and for each `Mutant*` configuration under
`==> session-move (TLA+)`. Without the jar or a usable Java, the gate prints
`SKIP tla_models: ...` and goes on to the P models. The skip census refuses
that line in CI, so the prerequisites are required there.

## Results

Against the model as committed, with `MaxInc = 3` and `MaxCrashes = 2`, on
TLC 2.19 (one worker):

| Configuration | Outcome | States generated | Distinct | Depth |
|---|---|---|---|---|
| `Move.cfg` | no error, `MoveSettles` holds | 1,179 | 392 | 20 |
| `MutantIntend.cfg` | `OneOwner` violated | 765 | 279 | 11 |
| `MutantAbort.cfg` | `OneOwner` violated | 700 | 254 | 10 |
| `MutantRefuse.cfg` | `OneOwner` violated | 555 | 216 | 10 |
| `MutantRetire.cfg` | `ActiveImpliesComplete` violated | 53 | 30 | 5 |

Reachability was also checked once by hand with throwaway invariants: B can
serve after `moved`; A can abort after the cut and reopen at incarnation 2; A
can crash after the send; A's reply can be lost while its mover waits; and a
restarted A can resume a cut copy. Dropping weak fairness of `Retire` or of
`Restart` makes `MoveSettles` fail, so the liveness check is not vacuous.

## Mutation checks

Each `Mutant*.cfg` turns one rule off through a constant and names, on its
`\* expect-violation:` line, the invariant TLC must then violate. The gate
fails if a mutant passes or violates a different invariant. A mutant
configuration lists only its target invariant, so the report names it even
when a weaker invariant breaks one step earlier.

| Mutation | Constant | Counterexample |
|---|---|---|
| `Intend` writes nothing | `IntendDurable = FALSE` | The copy is sent, B activates and serves. A then crashes and restarts, finds an `active` row and no mover, and serves again. `OneOwner` breaks. |
| `AbortEarly` allowed after the send | `AbortGuardsSent = FALSE` | B has the file and activates. A aborts, reopens at the next incarnation and serves. B attaches by rebinding the same incarnation and serves too. `OneOwner` breaks. |
| B refuses after its row is active | `RefuseUncommitted = FALSE` | B activates, and the reply is lost or the retry arrives. B refuses the retry, A treats the refusal as final and takes the session back, reopens it at the next incarnation and serves. B attaches by rebinding the same incarnation and serves too. `OneOwner` breaks. The shipped code did this when the owner had opened the session on B before the retry (the receiver answered busy), and when B no longer listed the sender. |
| `Retire` without the observation | `RetireObserves = FALSE` | A retires right after the send, before B's row is active. `ActiveImpliesComplete` breaks: `moved` with `b = absent`. |

To add a mutation, add a `Mutant<Name>.cfg` with an `expect-violation` line.
The gate discovers it without an edit to the script.

## The directory's moves: `KhepriMove.tla`

On a directory member the owner record decides who owns a session, and each
node's catalogue row is local memory of what the node is doing
(protocol-change/079). The record is one value, written only by
compare-and-set while a majority of the cluster is up. A node writes its row
before a change that takes serving away, the intent, and after a change that
grants it, the import. The model checks that no interleaving of crashes, lost
majorities, repeated activations and abandons leaves two nodes serving, a
node serving that the record does not name, or an owner without the newest
version of the session.

### What is modelled

Two orchestrators, A and B, one executor, and two moves: op 1 from A to B,
then op 2 from B back to A. The second move matters because it can start
while the first move's source is still finishing.

| Variable | Meaning |
|---|---|
| `reg` | The record, `[owner, st, op]`: `st` is `serving` or `moving`, and `op` names the move while it is `moving`. |
| `row`, `rowOp` | Each node's catalogue row (`resident`, `moving`, `moved`, `imported` or `absent`) and the op it names. |
| `quorum`, `qlosses` | Whether a majority is up, and how many times it was lost, bounded by `MaxQuorumLosses`. |
| `file`, `top` | The version of the session each node's file holds (0 for none), and the newest version ever written. |
| `copySt`, `copyVer` | Each op's copy (`none`, `cut`, `sent` or `placed`) and the version it was cut at. |
| `exec` | The executor ledger row, as in `Move.tla`. |
| `serving`, `alive`, `mover` | As in `Move.tla`, per node. |
| `intent`, `refused` | Memory of a node's mover: its intent write committed; its activation was refused. |
| `lastOp`, `sawOther`, `started` | History: the op that last changed the owner; whether the record ever named the other node; which moves began. |

### Actions

| Action | What it is |
|---|---|
| `AttachExec(n)`, `Open(n)`, `Edit(n)` | A node attaches, serves, and writes a new version. Opening needs the node's own row to allow it and reads nothing from the record. |
| `Intend(n, op)` | The registry turn: the row becomes `moving(op)`, serving stops, the mover starts. |
| `IntentCAS(n, op)` | `[n, serving]` to `[n, moving, op]`, or a repeat that finds it already written, or a record that names the receiver, after which the run carries on so the receiver is asked again. |
| `StopClose(n)`, `Cut(n, op)`, `Send(op)` | As in `Move.tla`. The cut carries the version of the file. A sender that runs again cuts and sends again, since it cannot see that a copy was placed. None runs while a refusal is held. |
| `CloseRefused(n)` | The executor refuses the close because the receiver holds the scope, which it can only do after importing. The mover holds it as a refusal. |
| `ActivateCAS(m, op)` | `[source, moving, op]` to `[m, serving]`. Not tied to the sender's mover: an activation can arrive any number of times once a copy is sent. |
| `Import(m, op)` | Once the record names `m`: the row becomes `imported(op)` and the copy is placed. |
| `RefuseConflict(m, op)` | The receiver's row holds the session in another state (including `moving`): refused before anything is written, and the incoming copy is dropped. |
| `RefuseEnded(m, op)` | The record names a third party, or no longer says the move: refused, dropping only the incoming copy. |
| `Abandon(n)` | `[n, moving, op]` to `[n, serving]`. The operator may ask at any time; after a refusal the mover must (`AbandonRefused`). |
| `Revert(n)` | The record names `n` serving: the row goes back to `resident`. |
| `Retire(n)` | The receiver has answered (a refusal is held, or the receiver holds the session `imported` under this op, which is what `Accepted` and a stage of `Activated` report) and a consistent read names the other node: the row becomes `moved` and the file is set aside. |
| `Delete(m)` | The owner deletes the session: the record becomes absent, and its row and file go. |
| `GoneRetire(n)` | A source whose mover is still on a move finds the record absent. Once a member has seeded, every session has a record, so a missing one means the owner deleted it: the row becomes `moved` and the file is set aside. |
| `Crash(n)`, `Restart(n)`, `QuorumLoss`, `QuorumBack` | Memory is lost and the rest survives; a restart resumes a mover for a `moving` row. |

### What is abstracted away

- Deletion is one step, `Delete`, with the record going absent for good; the
  `Deleting` mark and its retries are not modelled. The seed is not modelled
  either: the model starts with every session recorded, which is the state
  after the seed, so an absent record always means a deletion.
- `Revert` may run whenever its read allows, and `Retire` whenever the
  receiver's answer and its read allow, not only at the point in a run where
  the code takes them. That is a superset of what the code does, so a safety
  result holds for the code's narrower order.
- The receiver's steps may happen at any time once a copy is sent, which
  stands for activations still in flight; but they are fair only while the
  source is asking (`Asking`), because in the code they run inside the
  source's activation request. That is what lets the liveness properties see
  a receiver whose import nobody asks for.
- Local sessions have records too, but they never move; their record is a
  lookup hint and takes part in no step here.
- `Import` does not need a majority. The code learns that the record names
  it from a compare-and-set, which does; allowing it without one is again a
  superset.
- Two moves, `MaxVer = 2` (one write), `MaxInc = 3`, `MaxCrashes = 2` and
  `MaxQuorumLosses = 1`.

### Properties

| Property | Statement |
|---|---|
| `OneOwner` | `~(serving[A] /\ serving[B])`. |
| `ServeOnlyAsOwner` | A node serves only while the record names it. |
| `OwnerHasNewest` | The owner the record names holds the newest version, in its file or, between its activation and its import, in the copy that activation placed with it. No write is lost and no owner is left without the session. |
| `MovingIsRemembered` | A record that says `moving` has the row that says so on its owner, so a restart finds the move. |
| `NoResurrection` | Once the owner deleted the session, no node holds it in a row that lets it serve. |
| `OneServingHolder` | As in `Move.tla`. |
| `MoveSettles` | `reg.st = moving ~> reg.st = serving`. |
| `MoverEnds` | Every node's `moving` row comes to say `moved` or `resident`. |
| `OwnerCanServe` | `reg.st = serving ~> (reg.st = absent \/ Allows(reg.owner))`: whoever the record names as serving comes to hold the session in a row that lets it serve, unless it is deleted first. |

Reachability was checked by hand with throwaway invariants: the return move
completes and A serves it; A's row is still `moving(1)` while op 2's copy is
on A; the record says `moving` with the copy sent and no majority; the version
written on B reaches A; B abandons the return and serves; both rows say
`moved` at once. Dropping weak fairness of `Retire`, `Revert`, `QuorumBack` or
`Restart` makes the liveness properties fail, so they are not vacuous.

### Results

On TLC 2.19, one worker:

| Configuration | Outcome | States generated | Distinct | Depth |
|---|---|---|---|---|
| `KhepriMove.cfg` | no error, `MoveSettles` and `MoverEnds` hold | 60,226 | 17,205 | 32 |
| `KhepriMutantBlindAbandon.cfg` | `OneOwner` violated | 8,488 | 3,153 | 13 |
| `KhepriMutantBlindActivate.cfg` | `OneOwner` violated | 6,830 | 2,485 | 13 |
| `KhepriMutantImportBeforeCAS.cfg` | `ServeOnlyAsOwner` violated | 1,256 | 506 | 8 |
| `KhepriMutantImportOverMoving.cfg` | `OwnerHasNewest` violated | 18,465 | 6,276 | 17 |
| `KhepriMutantIntendBeforeStop.cfg` | `MovingIsRemembered` violated | 6 | 6 | 2 |
| `KhepriMutantRefuseOwned.cfg` | `OwnerHasNewest` violated | 768 | 317 | 7 |
| `KhepriMutantRetireStale.cfg` | `OwnerHasNewest` violated | 1,826 | 703 | 9 |

### Mutation checks

| Mutation | Constant | Counterexample |
|---|---|---|
| `KhepriMutantIntendBeforeStop` | `RevokeFirst = FALSE` | The intent CAS commits before the row that remembers it. `MovingIsRemembered` breaks at once; with a crash between the two, the record says `moving` and no restart resumes the move. |
| `KhepriMutantBlindActivate` | `ActivateExpects = FALSE` | A abandons and serves again; an activation still in flight takes the record for B, which imports and serves. `OneOwner` breaks. |
| `KhepriMutantBlindAbandon` | `AbandonExpects = FALSE` | B activated and serves; A's abandon takes the record back and A serves too. `OneOwner` breaks. |
| `KhepriMutantImportBeforeCAS` | `ImportAfterCAS = FALSE` | B imports while the record still names A, and serves. `ServeOnlyAsOwner` breaks. |
| `KhepriMutantImportOverMoving` | `ReceiverChecksRow = FALSE` | A crashed after op 1 activated; B wrote version 2 and moves it back. A's activation CAS commits while A's row is still `moving(1)`, the import is refused because of that row, and the copy holding version 2 is dropped: the record names A, which holds version 1. `OwnerHasNewest` breaks. |
| `KhepriMutantRefuseOwned` | `RefuseOnlyOthers = FALSE` | B's activation committed and B crashed before importing. B refuses the repeat although the record names it, and drops the only copy. `OwnerHasNewest` breaks. |
| `KhepriMutantRetireStale` | `RetireConsistent = FALSE` | B's return is refused, B abandons it, and B retires on a value from before it owned the session, setting aside the file it owns. `OwnerHasNewest` breaks. |
| `KhepriMutantGoneReverts` | `GoneSetsAside = FALSE` | A gives B the session and its mover stays on the move; B imports it and deletes it. A then finds no record and reverts its row, so it can serve a deleted session again. `NoResurrection` breaks. |
| `KhepriMutantRetireOnSilence` | `RetireOnAnswer = FALSE` | B's activation commits and B crashes before importing. A retires on the record alone and stops asking, so nothing makes B import: the record names B for ever, and B holds only the incoming copy. `OwnerCanServe` breaks (a temporal property, exit 13). |

`KhepriMutantImportOverMoving` is the rule in `session_importer.activated`:
a receiver whose row holds the session in any state but the one the move left
it in refuses before it writes the record. The code had that check from the
phase 5 importer, and the model says it is load-bearing on a member, where the
refusal comes before the compare-and-set.
