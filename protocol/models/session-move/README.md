# Session move protocol models

Three [TLA+](https://lamport.azurewebsites.net/tla/tla.html) specifications live
here. `Move.tla` is the move where each orchestrator's catalogue row decides
who owns the session, which every deployment without a `[directory]` runs.
`KhepriMove.tla` is the same move, and a move back, where the session
directory's owner record decides (protocol-change/083); it is described in
the next-to-last part of this file. `MoveCheckout.tla` is `Move.tla` with the
checkout step of a session that works in a directory
(protocol-change/107, slice 4c); it is described in the last part.
`make model-check` checks all three.

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
(protocol-change/083). The record is one value, written only by
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
| `KhepriMutantRefuseOwned` | `RefuseOnlyOthers = FALSE` | B's activation committed and B crashed before importing. B refuses the repeat although the record names it, and drops the only copy. `OwnerHasNewest` breaks. In the code every refusal is held to this rule, whatever its reason (a missing executor, an unlisted sender, a copy that does not check): a receiver that owns the record answers `Failed` instead (`session_importer.owned_import`, `kept_if_owned`), so the model's one `Refuse` stands for all of them. |
| `KhepriMutantRetireStale` | `RetireConsistent = FALSE` | B's return is refused, B abandons it, and B retires on a value from before it owned the session, setting aside the file it owns. `OwnerHasNewest` breaks. |
| `KhepriMutantGoneReverts` | `GoneSetsAside = FALSE` | A gives B the session and its mover stays on the move; B imports it and deletes it. A then finds no record and reverts its row, so it can serve a deleted session again. `NoResurrection` breaks. |
| `KhepriMutantRetireOnSilence` | `RetireOnAnswer = FALSE` | B's activation commits and B crashes before importing. A retires on the record alone and stops asking, so nothing makes B import: the record names B for ever, and B holds only the incoming copy. `OwnerCanServe` breaks (a temporal property, exit 13). |

`KhepriMutantImportOverMoving` is the rule in `session_importer.activated`:
a receiver whose row holds the session in any state but the one the move left
it in refuses before it writes the record. The code had that check from the
phase 5 importer, and the model says it is load-bearing on a member, where the
refusal comes before the compare-and-set.

## The checkout step: `MoveCheckout.tla`

A session whose workspace is a directory on the source has no executor scope to
hand over. The seventh step of a move, `client/move_checkout`
(protocol-change/107, slice 4c), gives it one. After the stop and before the
close, the source captures the directory in full (a dirty tree becomes a
`Working snapshot` commit), sends the state to the destination's
`checkout_executor`, attaches a scope there, issues one fenced `StateApply`
under the scope's incarnation and token, closes the scope, and records its
progress in the reserved session-file cell `client/move/checkout`. The six steps
then run as for any session on that executor. The step merged without a model.

`MoveCheckout.tla` EXTENDS `Move.tla` and reuses its actions, each wrapped so
that it leaves the checkout variables alone. It adds the step's own actions, the
laptop directory as a git repository, the executor's branch and tree, the
network between the source and the executor, and the operator. The model is
plain TLA+. There is no PlusCal source, so nothing needs to be translated.

The step sits between `StopA` and `Cut`. It writes one `Move.tla` variable,
`exec`, with the ledger rule `Move.tla` already uses for an attach and a close.
`Cut` and `Send` need the checkout recorded as done (`pc = "marked"`). The
checkout does not read or write `servingA`, `servingB` or `b`, so `OneOwner`
cannot change because of it. The composite configuration still checks `Move.tla`'s
`OneOwner`, `NoResurrection`, `ActiveImpliesComplete` and `OneServingHolder`.

Two of `Move.tla`'s actions do not apply to a local session and are replaced.
`AttachExec("A")` and `OpenA` give way to `OpenALocal`, because a local session
serves from the directory and holds no scope. `StopA` runs only to stop a
serving runtime. B's attach is wrapped so that it mints a token, since the fence
on the source's request compares tokens.

### What is modelled

| Variable | Meaning |
|---|---|
| `par`, `cnt`, `nc` | The commit store: each commit's parent and content, and the next free id. Commits 0 and 1 are a parent and child, 2 is an unrelated root. |
| `head`, `wt`, `nw` | The laptop's HEAD, the content of its working tree, and the next edit's content. A tree is clean when `wt = cnt[head]`. |
| `edits`, `opView` | Operator changes so far, bounded; what the operator last left, `<<head, wt>>`. |
| `att`, `stopWt` | The move attempt number, and the working tree's content when the attempt began. |
| `cell` | The progress cell in the session file: the attempt (`op`), `ph` (`none`, `taken` or `done`) and the captured tip. |
| `srcStore`, `store` | The tips held by the source's state store and by the executor's. |
| `exBranch`, `applied` | The tip of the branch `loom/<session>` on the executor, and the tip of the last apply. `-1` is none. |
| `tok`, `tokAtt` | The scope's attach token, and the attempt that minted it. |
| `cfgWs`, `bound` | The configured `checkout_workspace`: `good` (a `worktree` workspace the executor serves), `shared` (served in `shared` mode, which refuses a state) or `unknown` (a name the executor does not serve). And the workspace the executor's ledger has bound the session's scope to, or `none`. |
| `net`, `answers` | `StateApply` requests in flight to the executor, and replies in flight to the source. |
| `aliveX`, `lastLand` | The executor is up; how the last apply that changed the tree was admitted. |
| `pc`, `mtip`, `mtipAtt`, `mreq`, `minc`, `mtok` | The mover's memory: its place in the step, the state it carries, the attempt that captured it, the request it waits on, and the scope it attached. Lost by a crash. |
| `reruns`, `lost` | Re-entries of the step without a crash, and lost replies, both bounded. |

The mover's `pc` takes the values `idle`, `start`, `captured`, `recorded`,
`sent`, `attached`, `asked`, `applied`, `rejected`, `closed`, `refused` and
`marked`.

### Actions

| Action | What it is |
|---|---|
| `OpEdit`, `OpCommit`, `OpDiscard`, `OpReset` | The operator changes the directory: edits it, commits the edit, discards uncommitted edits, or resets HEAD to its parent. Allowed only while the session is resident and no move runs, so also between an abandon and a retry. |
| `OpenALocal` | A serves the session from the directory. |
| `Intend2` | Move's `Intend`, which also starts attempt `att + 1` and records the working tree. |
| `CkRead` | `carry` reads the cell. A `done` cell of this attempt skips the step; a `taken` cell of this attempt is used again while the source's store holds the tip; anything else starts at the capture. |
| `CkCapture` | The capture. A clean tree has HEAD as its tip. A dirty tree becomes a new snapshot commit on top of HEAD. |
| `CkRecord`, `CkSend` | The cell is written; the state is sent whole to the executor. |
| `CkAttach` | The source attaches a scope for the landing. An open scope accepts a rebind at its own incarnation; a closed one reopens at the next. The first attach branches the executor's tree from the workspace's base, and a reopen recreates the tree from `loom/<session>`. |
| `CkAttachUnknown`, `FixConfig` | An attach that names a workspace the executor does not serve: the ledger binds the scope to the name and the plane cannot be built, so the attach fails and the move stalls with the scope open. The operator corrects the configuration and restarts the daemon (the mover's memory is lost; no crash is spent). An attach that names a workspace other than the one the scope is bound to is refused by the ledger, and the source reports the refusal as a string it cannot tell from a lost connection, so the move stalls and no action is enabled. |
| `CkAsk`, `CkResend` | One `StateApply` under the scope's incarnation and token, put in the network; the same request again when no reply came. |
| `ExApply`, `ExRefuse`, `LoseAnswer` | The executor takes a request. It judges the fence first, then `holds_tip`, and moves the branch with `checkout -B` only when the rule says the tree does not hold the tip. Or it refuses the apply for good. A reply is lost. |
| `CkReceive`, `CkClose`, `CkMark` | The source takes the reply, closes the scope on every path (which removes the tree and keeps the branch), and writes the `done` cell. |
| `CkRerun` | The step stalls and is run again from the cell. The scope it left is not closed by it, and a request it sent runs on. |
| `AbandonCapture`, `AbandonSend`, `AbandonLanded` | The refusals of the step: the capture is refused, the executor's store declines the state, or the apply is refused for good (after which the scope is closed). Each abandons the move. |
| `AbortEarly2`, `RefuseActivate2` | Move's later abandons, allowed once the checkout is done. |
| `CrashA2`, `CrashB2`, `CrashX`, `RestartX`, `Restart2` | Crashes of the source, the destination and the executor share `MaxCrashes`. The source's crash loses `pc` and the replies in flight. The executor's crash loses the requests it has not run and keeps its ledger, store and branch. |

`ExApply` is the rule under test. `HoldsRule = "ancestry"` is
`state_apply.holds_tip` as shipped: the tree is left alone when the tip is HEAD
or an ancestor of HEAD (`git merge-base --is-ancestor <tip> HEAD`).
`HoldsRule = "applied"` is the rule the checkout needs: the tree is left alone
when its HEAD is the tip or the last apply for the session was of this tip.

### What is abstracted away

- The state is sent whole in one step, as `Move.tla` sends the copy. The
  state-transfer P model checks the pieces and the resume offsets.
- An apply is one step: the fence check, `holds_tip` and `checkout -B` happen
  together. The shipped apply runs to its end even when the scope is closed
  during it, which the 107 addendum lists as an accepted cost. It is not
  modelled.
- A commit's content is a number. A tree is clean or holds one edit, and an edit
  is a new content. File-level changes, untracked files and ignored files are
  not modelled. The tree on the executor is always clean, because only the apply
  writes it.
- The store forgets nothing. The source's `Taken` cell is always usable while
  its tip is in `srcStore`, which is the only state it needs.
- Source-side abandons are the three refusals of the step and Move's own. An
  abandon on request, which only a directory member has, is the constant
  `OperatorAbandon`, off in the clean configuration. A directory member does not
  move a local session in the shipped code (the 107 addendum, changes after
  review), and a daemon that decides by catalogue rows stalls an abandon on
  request. The mutant `MoveCheckoutMutantOperatorAbandon` records what building
  that path has to close.
- A close that finds the executor down waits for it. In the shipped `landing`,
  `close_scope` writes how the close ended into the session file, and a close that
  was never recorded is settled by the mover's `closed` step, which asks the
  executor to close the scope (`asked_to_close`). The model's wait stands for that.
- Bounds: `MaxAtt = 2` attempts, `MaxEdits = 2` operator changes,
  `MaxCrashes = 1`, `MaxReruns = 1`, `MaxLost = 1`, `MaxInc = 7`,
  `MaxTok = 7` and `MaxCommits = 8`. The commit, token and incarnation bounds
  are large enough that no bound ends a run that a fault bound allows, which
  `CheckoutSettles` would report.

### Properties

| Property | Statement |
|---|---|
| `CheckoutIsWhatWasStopped` | Once the destination owns the session (`b = active` or `a = moved`), the executor's branch holds exactly the content that the laptop directory had when this attempt began. Not the content of an abandoned attempt's snapshot, and not a tree that the executor already had. |
| `LaptopUntouched` | The directory is as the operator last left it: `<<head, wt>> = opView`. The step never writes it. |
| `NoApplyOutsideFence` | An apply that changed the tree was admitted by the fence, and the scope it was admitted under was minted by the current attempt. |
| `AbandonRestores` | After an abandon the laptop owns the session alone (`a = active => b = absent`), the mover never holds a state that another attempt captured, and a corrected configuration is not blocked: once `cfgWs = good` an attach is allowed, so no scope that a failed attempt left stays bound to the workspace it named. |
| `NoLeak` | A settled move leaves no scope that the source attached: not after an abandon, and not after the hand-over. |
| `CheckoutSettles` | `a = moving ~> a \in {moved, active}`, under weak fairness of every protocol step and restart of the step and of Move, and of the operator's correction of a wrong configuration (`FixConfig`). Operator edits of the directory, refusals, lost replies, reruns and abandons are not fair. |

`NoLeak` is stated for the scope. The cell is another matter: the shipped step
leaves `client/move/checkout` in the session file after the move settles, and it
names the finished attempt. `CellNamesNoFinishedAttempt` says otherwise and is
false of the shipped code (the reachability check below reaches a state that
violates it). A later attempt ignores a cell of another attempt, which is the
rule `CellChecksOp` and the property `AbandonRestores` hold to, so the cell is
a few hundred bytes of leftover and not a state any step trusts. It is recorded
here because the property was asked for in that form.

### Running it

```sh
java -cp ~/tools/tla2tools.jar tlc2.TLC -workers 1 -config protocol/models/session-move/MoveCheckout.cfg protocol/models/session-move/MoveCheckout.tla
```

or `make model-check`, which also runs every mutant. The gate finds the
mutants by the name `MoveCheckoutMutant*.cfg`, and runs every further clean
configuration named `MoveCheckoutAlso*.cfg`, which must pass as well.
`MoveCheckout.cfg` has a correct workspace and edits the directory;
`MoveCheckoutAlsoWorkspaces.cfg` starts with a wrong workspace and does not.

### Results

On TLC 2.19:

| Configuration | Outcome | States generated | Distinct | Depth |
|---|---|---|---|---|
| `MoveCheckout.cfg` | no error, `CheckoutSettles` holds | 903,556 | 319,215 | 53 |
| `MoveCheckoutAlsoWorkspaces.cfg` | no error, `CheckoutSettles` holds | 336,894 | 102,452 | 58 |
| `MoveCheckoutMutantHoldsTipAncestry.cfg` | `CheckoutIsWhatWasStopped` violated | 276,608 | 117,322 | 29 |
| `MoveCheckoutMutantHoldsTipAhead.cfg` | `CheckoutIsWhatWasStopped` violated | 12,919 | 5,975 | 15 |
| `MoveCheckoutMutantCellAnyOp.cfg` | `AbandonRestores` violated | 1,023 | 492 | 8 |
| `MoveCheckoutMutantUnfencedApply.cfg` | `NoApplyOutsideFence` violated | 7,527 | 3,466 | 13 |
| `MoveCheckoutMutantCaptureCommits.cfg` | `LaptopUntouched` violated | 169 | 86 | 5 |
| `MoveCheckoutMutantOperatorAbandon.cfg` | `NoLeak` violated | 1,962 | 779 | 8 |
| `MoveCheckoutMutantScopeKeepsWorkspace.cfg` | `AbandonRestores` violated | 1,913 | 813 | 8 |
| `MoveCheckoutMutantScopeKeepsWorkspaceStall.cfg` | `CheckoutSettles` violated | n/a | n/a | n/a |

A deeper run, outside the gate and before the workspace binding was added to
the model, with `MaxCrashes = 2`, `MaxInc = 9`, `MaxTok = 9` and
`MaxCommits = 10`, found no error in 6,657,106 states generated, 1,937,932
distinct, depth 63, in 5 minutes 48 seconds with two workers. A run of
`MoveCheckout.cfg` with `InitWs = {good, shared, unknown}` in one configuration
found no error in 4,776,865 states generated, 1,532,620 distinct, depth 60, in
475 seconds; the gate splits it into two configurations to stay shorter.

Reachability was checked by hand with throwaway invariants that TLC must
violate, which shows the model reaches the state: B serves after the hand-over;
a move that was abandoned after its checkout is asked for again and completes;
a leaked scope with the mover run again; a stale request refused by the fence;
a reply lost and the request sent again; an apply refused for good and the
move abandoned; a source that crashed after the cut resumes from the `done`
cell; the executor down while the scope is open; an operator edit between an
abandon and a retry; a request still in flight whose token is no longer the
scope's; and the cell naming a finished attempt. Dropping weak fairness of
`CkMark`, `CkResend`, `RestartX`, `Restart2` or `AbandonLanded` makes
`CheckoutSettles` fail, so the liveness check is not vacuous.

### Mutation checks

| Mutation | Constant | Counterexample |
|---|---|---|
| The shipped `holds_tip`, with an executor workspace that is not ahead | `HoldsRule = "ancestry"`, `BaseAhead = FALSE` | See the finding below. An abandoned attempt left its snapshot on the executor's branch, and a retry after the operator discarded the edits is taken for done. |
| The shipped `holds_tip`, with an executor workspace that is ahead | `HoldsRule = "ancestry"`, `BaseAhead = TRUE` | See the finding below. The first apply of a clean laptop is taken for done. |
| A cell is believed for any move | `CellChecksOp = FALSE` | An abandoned attempt's `done` cell is found by the next attempt, which skips its capture and carries the earlier state. |
| The executor applies without judging the fence | `FenceApply = FALSE` | A request left in flight by a crashed run lands under the scope a later run attached. |
| The capture commits into the laptop's repository | `CaptureLeavesLaptop = TRUE` | The directory's HEAD moves to the snapshot. |
| An abandon on request arrives while the scope is open | `OperatorAbandon = TRUE` | The abandon after the attach and before the close leaves the scope open, so the executor's slot stays held. |
| The ledger keeps a scope bound to a workspace after a failed landing, and a refused apply | `RebindUnused = FALSE`, `InitWs = {shared}` | See the finding below. The corrected workspace is refused for the scope's binding. `AbandonRestores` breaks. |
| The same, with a name the executor does not serve | `RebindUnused = FALSE`, `InitWs = {unknown}` | The attach binds the scope and fails, and the corrected attach is refused. The move never settles, so `CheckoutSettles` breaks (exit 13). |

### Finding: `holds_tip` takes a stale tree for the state that was asked for (lines read at 024afdadf)

`CheckoutIsWhatWasStopped` does not hold of the shipped code. The model finds two
traces, both with `state_apply.holds_tip` as written (`git merge-base
--is-ancestor <tip> HEAD`). The code path of each step was read again, and each
is reachable from real inputs.

**An executor that is ahead (the first attempt).** `MoveCheckoutMutantHoldsTipAhead.cfg`,
15 steps. The laptop directory is clean at commit X. The executor's workspace
repository is at Y, a descendant of X (a box that has pulled further than the
laptop has). No abandon is needed.

1. `session_mover.carried` (`session_mover.gleam:519`) calls `checked_out`
   (`:726`), which calls `move_checkout.carry` (`move_checkout.gleam:288`),
   `fresh` (`:309`) and `captured` (`:331`).
2. The capture of a clean tree has HEAD as its tip: `repository_snapshot.tip_of`
   (`repository_snapshot.gleam:835`, the `Clean` arm at `:853`). The tip is X.
3. `sent` sends X. `landing` (`move_checkout.gleam:553`) calls `attach_and_apply`
   (`:602`). The executor's first attach for the session creates the tree with
   `git worktree add <path> -b loom/<session> <base>` (`worktrees.create`,
   `worktrees.gleam:966`, the command at `:982`). `base` is `HEAD` unless the
   workspace sets another (`workspaces.default_base`), so the tree is at Y.
4. `hands.apply_state` (`move_checkout.gleam:628`) reaches the executor as
   `StateApply` (`host.apply_state`, `remote/host.gleam:968`), then
   `state_capture.apply` (`state_capture.gleam:236`) and `state_apply.apply` with
   a `Reset` placement, `into_existing` (`state_apply.gleam:606`).
5. `holds_tip(git, worktree, X)` (`:619`, defined at `:784`) runs `git merge-base
   --is-ancestor X HEAD`. HEAD is Y, X is its ancestor, Git exits 0, and
   `into_existing` answers `Ok(applied)` at `:624` without a checkout.
6. `placed` takes the answer (`move_checkout.gleam:365`; the comment at `:380` says
   the tip is not read), `delivered` records `done` (`:324`), and the close
   (`:632`) removes the tree and keeps the branch at Y. The receiver's attach
   recreates the tree from that branch (`worktrees.recreate`, `:1056`). The
   session continues at Y, not at the commit the laptop had.

**A retry after an abandon.** `MoveCheckoutMutantHoldsTipAncestry.cfg`, 29 steps
(the 107 addendum records this one as accepted). The laptop directory holds an
uncommitted edit.

1. Attempt 1 captures a snapshot commit S on top of HEAD (`tip_of`, the dirty
   arm), sends it, and lands it: the executor's tree is at S, then the close keeps
   `loom/<session>` at S.
2. The move is abandoned after the landing. In the code this is the receiver's
   refusal of the activation (`asked_to_activate`, `session_mover.gleam:1091`, the
   refusal arm that ends in `Abandon`), which `abandon` (`:1288`) turns into
   `revert` (`:1295`, `:1381`). The session is resident on the laptop.
3. The operator discards the edit (`git checkout .`) and asks for the move again.
   The new operation has a new id, so the cell is ignored
   (`move_checkout.remembered`, `:413`, the check at `:418`), and the capture of
   the now clean tree has HEAD, H, as its tip.
4. The landing attaches again. The scope record names the same executor, the
   scope is closed, and the executor recreates the tree from the existing branch
   (`worktrees.recreate`, the branch case at `worktrees.gleam:1066`), at S.
5. `holds_tip(git, worktree, H)` runs `git merge-base --is-ancestor H HEAD` with
   HEAD at S. H is S's parent, Git exits 0, and `into_existing` answers
   `Ok(applied)` (`state_apply.gleam:624`). The tree stays at S.
6. The receiver continues in a tree that holds the edits the operator discarded.

`state_apply.holds_tip` exists so that a resend after a lost reply is harmless,
including after the session has begun to commit on top. Ancestry cannot tell that
case from these two. What distinguishes them is whether the tree was last set by
this state, which is what `HoldsRule = "applied"` records. The clean
configuration uses that rule, so it checks the design that the checkout needs
and not the shipped code. The two mutants above are the shipped rule, and
`make model-check` shows them as expected violations for as long as the code
keeps it.

The fix is in a separate change, `distributed/move-checkout-stale-tip`. It
records the last apply per session on the executor in a ref
`refs/loom/applied/<session>`, written after `checkout -B`. `into_existing` then
leaves a tree alone when that ref names the tip, which keeps the resend rule of
slice 4a (a resend after the session committed on top), or when the tree's HEAD
is the tip, and moves the tree in every other case. Its regression tests fail
against the earlier rule. The model separates the ancestry rule from plain
equality of the tree's HEAD with the tip, but it has no step that commits on the
executor's branch, so the resend after the session committed on top is covered by
`applying_into_the_same_tree_twice_changes_nothing_test` in `state_apply_test`
and not by the model. The drive of exit criterion 2 reproduced the retry
trace on real daemons (`docs/review/distributed-1137.md`, finding 2). The two
mutants above are the rule before that change. Until it merges, `make
model-check` shows them as expected violations of the code on `main`.

### Finding: a failed landing leaves the scope bound to the wrong workspace (lines read at 024afdadf)

`AbandonRestores` and `CheckoutSettles` do not hold of the shipped code either.
The drive of exit criterion 2 found it on real daemons (`docs/review/distributed-1137.md`,
finding 1), and the model reproduces both of its cases.
`MoveCheckoutMutantScopeKeepsWorkspace.cfg` is the refused case, eight steps:

1. The configured `checkout_workspace` names a workspace the executor serves in
   `shared` mode. The checkout reaches `attach_and_apply`
   (`move_checkout.gleam:602`), whose attach makes the executor's ledger bind the
   session's scope to that workspace (`exec_ledger.attach`).
2. The apply is refused, because a state is applied only into a `worktree`
   workspace. `landing` closes the scope and reports a final refusal, so the move
   is abandoned and the session is resident on the laptop.
3. The operator corrects `checkout_workspace`, restarts the daemon and moves
   again. The attach names the corrected workspace. `exec_ledger.same_workspace`
   (`exec_ledger.gleam:1904`) compares it with the workspace the scope was bound
   to, which is the first one, and answers `WorkspaceMismatch`.
4. The source cannot tell that answer from a lost connection (`attach_and_apply`
   reports an attach error as `LandUnfinished`), so the move stalls. A daemon that
   decides by catalogue rows has no abandon on request, and `loom executor
   release` finds a closed scope. The session stays `moving` and cannot be opened.

`MoveCheckoutMutantScopeKeepsWorkspaceStall.cfg` is the stalled case. The name is
one the executor does not serve, the attach binds the scope to it and fails to
build the plane, and the scope stays open. With a fair operator who corrects the
name, the corrected attach is refused in the same way and `CheckoutSettles`
fails.

The rule the clean configurations check is `RebindUnused`: an attach that names
another workspace rebinds a scope that has no tree record, which is every scope a
failed landing leaves (the tree record is made by the first successful attach to a
`worktree` workspace). `MoveCheckoutAlsoWorkspaces.cfg` checks it with each wrong
configuration and a correction. It is not implemented. The change is to
`exec_ledger.attach_existing`, and it has a cost the model does not show: the
binding also protects a live session in a `shared` workspace, which has no tree
record and would then rebind silently to another workspace if its configuration
changed under it. The options are to allow the rebind only for a scope the move
created (the landing would name itself in the attach, which is a wire change), to
allow it only for a closed scope and give the operator a release of an open one
that is bound to a workspace the executor does not serve, or to have the executor
bind the scope only after its plane is built, which leaves the refused-apply case
to the first option.
