# Session move protocol model

A [TLA+](https://lamport.azurewebsites.net/tla/tla.html) model of one
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
