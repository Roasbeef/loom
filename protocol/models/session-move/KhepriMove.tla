---------------------------- MODULE KhepriMove ----------------------------
(***************************************************************************)
(* A session's moves between two orchestrators A and B when the session    *)
(* directory's owner record decides who owns it (protocol-change/079).     *)
(* Move.tla is the same protocol where each node's catalogue row decides;  *)
(* a deployment without a [directory] still runs that one, and both are    *)
(* checked.                                                                *)
(*                                                                         *)
(* Here the record decides and the rows remember. The record is one value  *)
(* [owner, st, op], written only by compare-and-set while a majority of    *)
(* the cluster is up. Each node keeps its catalogue row as local memory:   *)
(* it is written before a change that takes serving away (the intent) and  *)
(* after a change that grants it (the import), so a node never serves on   *)
(* the strength of a write that did not commit.                            *)
(*                                                                         *)
(* There are two moves, op 1 from A to B and op 2 from B back to A, so the *)
(* model covers a return while the first move's source may still be        *)
(* finishing. The session's content has a version: the node that serves    *)
(* may write, and a file or a copy carries the version it holds. That is   *)
(* what lets the model tell a node serving the session from a node         *)
(* serving an old copy of it.                                              *)
(*                                                                         *)
(* The receiver's activation is not tied to the sender's mover: once a     *)
(* copy is sent, an activation may be delivered at any time, any number of *)
(* times, which stands for retries and for a request still in flight when  *)
(* the sender gave up. The sender may abandon a move at any time, which is *)
(* the operator's hand-abandon; after a refusal it must.                   *)
(*                                                                         *)
(* Eight constants each switch one rule off so that its mutation can be    *)
(* checked. A clean run sets all eight to TRUE. Each KhepriMutant*.cfg     *)
(* sets one to FALSE and names the property TLC must then violate.         *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    RevokeFirst,       \* The intent row is written before the intent CAS.
    ActivateExpects,   \* The activation CAS expects [source, moving, op].
    AbandonExpects,    \* The abandon CAS expects [self, moving, op].
    ImportAfterCAS,    \* The receiver imports only once the record names it.
    ReceiverChecksRow, \* The receiver writes nothing while its row holds
                       \* the session in another state.
    RefuseOnlyOthers,  \* The receiver refuses only when the record names
                       \* someone else.
    RetireConsistent,  \* The source retires on a current read of the record.
    RetireOnAnswer,    \* The source retires only once the receiver answered.
    MaxInc,            \* Bound on the executor incarnation.
    MaxVer,            \* Bound on the session's content version.
    MaxCrashes,        \* Bound on crashes of either node.
    MaxQuorumLosses    \* Bound on losses of the cluster's majority.

Nodes == {"A", "B"}

Ops == {1, 2}

Src(op) == IF op = 1 THEN "A" ELSE "B"

Dst(op) == IF op = 1 THEN "B" ELSE "A"

Other(n) == IF n = "A" THEN "B" ELSE "A"

VARIABLES
    reg,       \* The owner record: [owner, st, op]; op is 0 while serving.
    lastOp,    \* History: the op of the activation that last changed owner.
    sawOther,  \* History: per node, the record ever named the other node.
    quorum,    \* A majority of the cluster is up.
    qlosses,   \* Losses of the majority so far.
    row,       \* Per node, the catalogue row: see TypeOK.
    rowOp,     \* Per node, the op the row names, 0 for none.
    file,      \* Per node, the version of the session file it holds, 0 none.
    top,       \* The newest version ever written.
    copySt,    \* Per op, the copy: none, cut (on the source), sent, placed.
    copyVer,   \* Per op, the version the copy was cut at.
    exec,      \* The executor ledger row, as in Move.tla.
    serving,   \* Per node, a runtime serves the session.
    alive,     \* Per node, the process is up.
    mover,     \* Per node, the mover task: idle or run.
    intent,    \* Per node, the mover has seen its intent CAS commit.
    refused,   \* Per node, the mover holds a refusal of its activation.
    started,   \* Per op, the move has begun.
    crashes    \* Crashes so far.

vars == <<reg, lastOp, sawOther, quorum, qlosses, row, rowOp, file, top,
          copySt, copyVer, exec, serving, alive, mover, intent, refused,
          started, crashes>>

Serving(n) == [owner |-> n, st |-> "serving", op |-> 0]

Moving(n, op) == [owner |-> n, st |-> "moving", op |-> op]

Holders == {"none", "A", "B"}

TypeOK ==
    /\ reg \in [owner : Nodes, st : {"serving", "moving"}, op : 0..2]
    /\ lastOp \in 0..2
    /\ sawOther \in [Nodes -> BOOLEAN]
    /\ quorum \in BOOLEAN
    /\ qlosses \in 0..MaxQuorumLosses
    /\ row \in [Nodes -> {"resident", "moving", "moved", "imported", "absent"}]
    /\ rowOp \in [Nodes -> 0..2]
    /\ file \in [Nodes -> 0..MaxVer]
    /\ top \in 1..MaxVer
    /\ copySt \in [0..2 -> {"none", "cut", "sent", "placed"}]
    /\ copyVer \in [0..2 -> 0..MaxVer]
    /\ exec \in [inc : 0..MaxInc, holder : Holders]
    /\ serving \in [Nodes -> BOOLEAN]
    /\ alive \in [Nodes -> BOOLEAN]
    /\ mover \in [Nodes -> {"idle", "run"}]
    /\ intent \in [Nodes -> BOOLEAN]
    /\ refused \in [Nodes -> BOOLEAN]
    /\ started \in [Ops -> BOOLEAN]
    /\ crashes \in 0..MaxCrashes

(* A created the session, recorded itself as its owner and holds version 1. *)
Init ==
    /\ reg = Serving("A")
    /\ lastOp = 0
    /\ sawOther = [n \in Nodes |-> n # "A"]
    /\ quorum = TRUE
    /\ qlosses = 0
    /\ row = [n \in Nodes |-> IF n = "A" THEN "resident" ELSE "absent"]
    /\ rowOp = [n \in Nodes |-> 0]
    /\ file = [n \in Nodes |-> IF n = "A" THEN 1 ELSE 0]
    /\ top = 1
    /\ copySt = [o \in 0..2 |-> "none"]
    /\ copyVer = [o \in 0..2 |-> 0]
    /\ exec = [inc |-> 0, holder |-> "none"]
    /\ serving = [n \in Nodes |-> FALSE]
    /\ alive = [n \in Nodes |-> TRUE]
    /\ mover = [n \in Nodes |-> "idle"]
    /\ intent = [n \in Nodes |-> FALSE]
    /\ refused = [n \in Nodes |-> FALSE]
    /\ started = [o \in Ops |-> FALSE]
    /\ crashes = 0

(* A write of the record, keeping the history variables. *)
Write(new) ==
    /\ reg' = new
    /\ sawOther' = [n \in Nodes |-> sawOther[n] \/ new.owner # n]

(* A row that lets its node serve. *)
Allows(n) == row[n] \in {"resident", "imported"}

(***************************************************************************)
(* Serving. A node opens the session when its own row allows it, no mover  *)
(* runs, and it holds the executor token. Opening reads nothing from the   *)
(* record. The node that serves may write, which makes a new version.      *)
(***************************************************************************)
AttachExec(n) ==
    /\ alive[n] /\ Allows(n) /\ mover[n] = "idle"
    /\ \/ /\ exec.holder # "none"
          /\ exec' = [exec EXCEPT !.holder = n]
       \/ /\ exec.holder = "none" /\ exec.inc < MaxInc
          /\ exec' = [inc |-> exec.inc + 1, holder |-> n]
    /\ UNCHANGED <<reg, lastOp, sawOther, quorum, qlosses, row, rowOp, file,
                   top, copySt, copyVer, serving, alive, mover, intent,
                   refused, started, crashes>>

Open(n) ==
    /\ alive[n] /\ Allows(n) /\ mover[n] = "idle"
    /\ exec.holder = n /\ ~serving[n]
    /\ serving' = [serving EXCEPT ![n] = TRUE]
    /\ UNCHANGED <<reg, lastOp, sawOther, quorum, qlosses, row, rowOp, file,
                   top, copySt, copyVer, exec, alive, mover, intent, refused,
                   started, crashes>>

Edit(n) ==
    /\ serving[n] /\ top < MaxVer
    /\ top' = top + 1
    /\ file' = [file EXCEPT ![n] = top + 1]
    /\ UNCHANGED <<reg, lastOp, sawOther, quorum, qlosses, row, rowOp,
                   copySt, copyVer, exec, serving, alive, mover, intent,
                   refused, started, crashes>>

(***************************************************************************)
(* The sender's intent, in the registry turn: the row becomes moving(op)   *)
(* and serving stops, and the mover starts. With RevokeFirst the intent    *)
(* CAS needs that row; the mutant lets the CAS run first, from a row that  *)
(* still allows serving, so a crash between the two leaves a record that   *)
(* says moving with no row to remember it.                                 *)
(***************************************************************************)
Intend(n, op) ==
    /\ Src(op) = n /\ ~started[op]
    /\ alive[n] /\ Allows(n) /\ mover[n] = "idle"
    /\ row' = [row EXCEPT ![n] = "moving"]
    /\ rowOp' = [rowOp EXCEPT ![n] = op]
    /\ serving' = [serving EXCEPT ![n] = FALSE]
    /\ mover' = [mover EXCEPT ![n] = "run"]
    /\ started' = [started EXCEPT ![op] = TRUE]
    /\ UNCHANGED <<reg, lastOp, sawOther, quorum, qlosses, file, top, copySt,
                   copyVer, exec, alive, intent, refused, crashes>>

IntentCAS(n, op) ==
    /\ Src(op) = n /\ alive[n] /\ quorum /\ ~intent[n]
    /\ IF RevokeFirst
          THEN row[n] = "moving" /\ rowOp[n] = op /\ mover[n] = "run"
          ELSE \/ row[n] = "moving" /\ rowOp[n] = op /\ mover[n] = "run"
               \/ ~started[op] /\ Allows(n) /\ mover[n] = "idle"
    /\ \/ /\ reg = Serving(n)
          /\ Write(Moving(n, op))
       \/ /\ reg = Moving(n, op)
          /\ UNCHANGED <<reg, sawOther>>
       \* The record names the receiver: its activation committed and its
       \* reply, or its import, was lost. The run carries on so that the
       \* receiver is asked again.
       \/ /\ reg.owner # n /\ mover[n] = "run"
          /\ UNCHANGED <<reg, sawOther>>
    /\ intent' = [intent EXCEPT ![n] = mover[n] = "run"]
    /\ UNCHANGED <<lastOp, quorum, qlosses, row, rowOp, file, top, copySt,
                   copyVer, exec, serving, alive, mover, refused, started,
                   crashes>>

(***************************************************************************)
(* The sender's steps once its intent has committed: close the scope, cut  *)
(* the copy at the version the file holds, and send it. None of them runs  *)
(* once a refusal is held: the run that heard it abandons or retires. A    *)
(* sender that runs again cannot see that the receiver already placed a    *)
(* copy, so it cuts and sends again, and the receiver answers from what it *)
(* holds.                                                                  *)
(***************************************************************************)
StopClose(n) ==
    /\ alive[n] /\ mover[n] = "run" /\ intent[n] /\ ~refused[n]
    /\ serving[n] \/ exec.holder = n
    /\ serving' = [serving EXCEPT ![n] = FALSE]
    /\ exec' = [exec EXCEPT !.holder = IF @ = n THEN "none" ELSE @]
    /\ UNCHANGED <<reg, lastOp, sawOther, quorum, qlosses, row, rowOp, file,
                   top, copySt, copyVer, alive, mover, intent, refused,
                   started, crashes>>

(***************************************************************************)
(* The executor refuses the close when the receiver holds the scope, which *)
(* it can only do once it imported the session. The code treats that as a  *)
(* final answer, as it treats a refusal.                                   *)
(***************************************************************************)
CloseRefused(n) ==
    /\ alive[n] /\ mover[n] = "run" /\ intent[n]
    /\ exec.holder = Other(n) /\ ~refused[n]
    /\ refused' = [refused EXCEPT ![n] = TRUE]
    /\ UNCHANGED <<reg, lastOp, sawOther, quorum, qlosses, row, rowOp, file,
                   top, copySt, copyVer, exec, serving, alive, mover, intent,
                   started, crashes>>

Cut(n, op) ==
    /\ Src(op) = n /\ alive[n] /\ mover[n] = "run" /\ intent[n]
    /\ ~refused[n] /\ row[n] = "moving" /\ rowOp[n] = op
    /\ ~serving[n] /\ exec.holder = "none" /\ copySt[op] \in {"none", "placed"}
    /\ copySt' = [copySt EXCEPT ![op] = "cut"]
    /\ copyVer' = [copyVer EXCEPT ![op] = file[n]]
    /\ UNCHANGED <<reg, lastOp, sawOther, quorum, qlosses, row, rowOp, file,
                   top, exec, serving, alive, mover, intent, refused, started,
                   crashes>>

Send(op) ==
    /\ alive[Src(op)] /\ mover[Src(op)] = "run" /\ rowOp[Src(op)] = op
    /\ ~refused[Src(op)]
    /\ copySt[op] = "cut"
    /\ copySt' = [copySt EXCEPT ![op] = "sent"]
    /\ UNCHANGED <<reg, lastOp, sawOther, quorum, qlosses, row, rowOp, file,
                   copyVer, top, exec, serving, alive, mover, intent, refused,
                   started, crashes>>

(***************************************************************************)
(* The receiver. Its own row is asked first: a row that holds the session  *)
(* in another state, moving included, is a refusal, and nothing is        *)
(* written (ReceiverChecksRow). Otherwise the activation CAS takes the     *)
(* record from [source, moving, op] to [receiver, serving], and only a     *)
(* record that names the receiver lets it import, which writes the row    *)
(* imported(op) and places the copy. A record that names someone else is  *)
(* a refusal that drops only the incoming copy (RefuseOnlyOthers).         *)
(***************************************************************************)
RowTakes(m, op) ==
    \/ row[m] = "absent"
    \/ row[m] = "moved" /\ rowOp[m] # op

RowRefuses(m, op) ==
    /\ ~RowTakes(m, op)
    /\ ~(row[m] = "imported" /\ rowOp[m] = op)

(* A refusal reaches a sender whose mover is still on this move. *)
Refuse(op) ==
    /\ copySt' = [copySt EXCEPT ![op] = "none"]
    /\ refused' = [refused EXCEPT ![Src(op)] =
                      @ \/ (alive[Src(op)] /\ mover[Src(op)] = "run"
                            /\ rowOp[Src(op)] = op)]

ActivateCAS(m, op) ==
    /\ Dst(op) = m /\ alive[m] /\ quorum /\ copySt[op] = "sent"
    /\ ReceiverChecksRow => RowTakes(m, op)
    /\ ActivateExpects => reg = Moving(Src(op), op)
    /\ reg # Serving(m)
    /\ Write(Serving(m))
    /\ lastOp' = op
    /\ UNCHANGED <<quorum, qlosses, row, rowOp, file, top, copySt, copyVer,
                   exec, serving, alive, mover, intent, refused, started,
                   crashes>>

Import(m, op) ==
    /\ Dst(op) = m /\ alive[m] /\ copySt[op] = "sent" /\ RowTakes(m, op)
    /\ ImportAfterCAS => reg.owner = m
    /\ row' = [row EXCEPT ![m] = "imported"]
    /\ rowOp' = [rowOp EXCEPT ![m] = op]
    /\ file' = [file EXCEPT ![m] = copyVer[op]]
    /\ copySt' = [copySt EXCEPT ![op] = "placed"]
    /\ UNCHANGED <<reg, lastOp, sawOther, quorum, qlosses, top, copyVer, exec,
                   serving, alive, mover, intent, refused, started, crashes>>

RefuseConflict(m, op) ==
    /\ Dst(op) = m /\ alive[m] /\ copySt[op] = "sent" /\ RowRefuses(m, op)
    /\ Refuse(op)
    /\ UNCHANGED <<reg, lastOp, sawOther, quorum, qlosses, row, rowOp, file,
                   top, copyVer, exec, serving, alive, mover, intent, started,
                   crashes>>

RefuseEnded(m, op) ==
    /\ Dst(op) = m /\ alive[m] /\ quorum /\ copySt[op] = "sent"
    /\ RowTakes(m, op)
    /\ reg # Moving(Src(op), op)
    /\ RefuseOnlyOthers => reg.owner # m
    /\ Refuse(op)
    /\ UNCHANGED <<reg, lastOp, sawOther, quorum, qlosses, row, rowOp, file,
                   top, copyVer, exec, serving, alive, mover, intent, started,
                   crashes>>

(***************************************************************************)
(* The sender's ends. Abandon is the CAS from [self, moving, op] back to   *)
(* [self, serving]; the operator may ask for it at any time, and a         *)
(* refusal makes the mover ask for it. The row is reverted only after the  *)
(* record says this node serves (Revert). Retire reads the record          *)
(* consistently, so it needs a majority, and retires only when the record  *)
(* names the other node: the row becomes moved and the file is set aside.  *)
(* It also needs the receiver's answer (RetireOnAnswer): a refusal, or the  *)
(* receiver holding the session imported, which is what Accepted and a     *)
(* stage of Activated report. A record that names the receiver is not      *)
(* enough, because the receiver may have crashed between its write and its *)
(* import, and only the source's next activation makes it import. The      *)
(* mutants retire on any value the record ever held, and on the record     *)
(* alone.                                                                  *)
(***************************************************************************)
Abandon(n) ==
    /\ alive[n] /\ mover[n] = "run" /\ row[n] = "moving" /\ quorum
    /\ IF AbandonExpects
          THEN reg = Moving(n, rowOp[n])
          ELSE reg # Serving(n)
    /\ Write(Serving(n))
    /\ UNCHANGED <<lastOp, quorum, qlosses, row, rowOp, file, top, copySt,
                   copyVer, exec, serving, alive, mover, intent, refused,
                   started, crashes>>

AbandonRefused(n) == refused[n] /\ Abandon(n)

(* A cut that never left the sender is removed with the end of its move. *)
DropCut(n) ==
    copySt' = [copySt EXCEPT ![rowOp[n]] = IF @ = "cut" THEN "none" ELSE @]

Revert(n) ==
    /\ alive[n] /\ mover[n] = "run" /\ row[n] = "moving" /\ quorum
    /\ reg = Serving(n)
    /\ row' = [row EXCEPT ![n] = "resident"]
    /\ mover' = [mover EXCEPT ![n] = "idle"]
    /\ intent' = [intent EXCEPT ![n] = FALSE]
    /\ refused' = [refused EXCEPT ![n] = FALSE]
    /\ DropCut(n)
    /\ UNCHANGED <<reg, lastOp, sawOther, quorum, qlosses, rowOp, file, top,
                   copyVer, exec, serving, alive, started, crashes>>

Answered(n) ==
    \/ refused[n]
    \/ /\ alive[Dst(rowOp[n])]
       /\ row[Dst(rowOp[n])] = "imported"
       /\ rowOp[Dst(rowOp[n])] = rowOp[n]

Retire(n) ==
    /\ alive[n] /\ mover[n] = "run" /\ row[n] = "moving"
    /\ RetireOnAnswer => Answered(n)
    /\ IF RetireConsistent
          THEN quorum /\ reg.owner # n
          ELSE sawOther[n]
    /\ row' = [row EXCEPT ![n] = "moved"]
    /\ file' = [file EXCEPT ![n] = 0]
    /\ mover' = [mover EXCEPT ![n] = "idle"]
    /\ intent' = [intent EXCEPT ![n] = FALSE]
    /\ refused' = [refused EXCEPT ![n] = FALSE]
    /\ DropCut(n)
    /\ UNCHANGED <<reg, lastOp, sawOther, quorum, qlosses, rowOp, top,
                   copyVer, exec, serving, alive, started, crashes>>

(***************************************************************************)
(* The environment. A crash loses memory and keeps the record, the rows,   *)
(* the files, the copies and the ledger; a restart resumes a mover for a   *)
(* moving row. The cluster loses and regains its majority.                 *)
(***************************************************************************)
Crash(n) ==
    /\ alive[n] /\ crashes < MaxCrashes
    /\ alive' = [alive EXCEPT ![n] = FALSE]
    /\ serving' = [serving EXCEPT ![n] = FALSE]
    /\ mover' = [mover EXCEPT ![n] = "idle"]
    /\ intent' = [intent EXCEPT ![n] = FALSE]
    /\ refused' = [refused EXCEPT ![n] = FALSE]
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<reg, lastOp, sawOther, quorum, qlosses, row, rowOp, file,
                   top, copySt, copyVer, exec, started>>

Restart(n) ==
    /\ ~alive[n]
    /\ alive' = [alive EXCEPT ![n] = TRUE]
    /\ mover' = [mover EXCEPT ![n] = IF row[n] = "moving" THEN "run" ELSE "idle"]
    /\ UNCHANGED <<reg, lastOp, sawOther, quorum, qlosses, row, rowOp, file,
                   top, copySt, copyVer, exec, serving, intent, refused,
                   started, crashes>>

QuorumLoss ==
    /\ quorum /\ qlosses < MaxQuorumLosses
    /\ quorum' = FALSE
    /\ qlosses' = qlosses + 1
    /\ UNCHANGED <<reg, lastOp, sawOther, row, rowOp, file, top, copySt,
                   copyVer, exec, serving, alive, mover, intent, refused,
                   started, crashes>>

QuorumBack ==
    /\ ~quorum
    /\ quorum' = TRUE
    /\ UNCHANGED <<reg, lastOp, sawOther, qlosses, row, rowOp, file, top,
                   copySt, copyVer, exec, serving, alive, mover, intent,
                   refused, started, crashes>>

Next ==
    \/ \E n \in Nodes :
          \/ AttachExec(n) \/ Open(n) \/ Edit(n) \/ StopClose(n) \/ CloseRefused(n)
          \/ Abandon(n) \/ Revert(n) \/ Retire(n) \/ Crash(n) \/ Restart(n)
    \/ \E n \in Nodes, op \in Ops : Intend(n, op) \/ IntentCAS(n, op) \/ Cut(n, op)
    \/ \E op \in Ops :
          \/ Send(op)
          \/ ActivateCAS(Dst(op), op) \/ Import(Dst(op), op)
          \/ RefuseConflict(Dst(op), op) \/ RefuseEnded(Dst(op), op)
    \/ QuorumLoss \/ QuorumBack

(***************************************************************************)
(* Fairness. Every protocol step, every restart and the return of the      *)
(* majority eventually happen while they stay enabled, and so does the     *)
(* abandon a refusal asks for. The receiver's steps are fair only while    *)
(* the source is asking (Asking), because in the code they run inside the  *)
(* source's activation request: a receiver that crashed after its write    *)
(* imports only when it is asked again. Crashes and losses of the majority *)
(* are bounded. The opens, the edits, the hand-abandon and the start of a  *)
(* move are not fair: a move must settle without them.                     *)
(***************************************************************************)
Asking(op) ==
    /\ alive[Src(op)] /\ mover[Src(op)] = "run"
    /\ row[Src(op)] = "moving" /\ rowOp[Src(op)] = op

Spec ==
    /\ Init /\ [][Next]_vars
    /\ \A n \in Nodes :
          /\ WF_vars(StopClose(n)) /\ WF_vars(Revert(n))
          /\ WF_vars(Retire(n)) /\ WF_vars(Restart(n))
          /\ WF_vars(AbandonRefused(n)) /\ WF_vars(CloseRefused(n))
    /\ \A n \in Nodes, op \in Ops : WF_vars(IntentCAS(n, op)) /\ WF_vars(Cut(n, op))
    /\ \A op \in Ops :
          /\ WF_vars(Send(op))
          /\ WF_vars(ActivateCAS(Dst(op), op) /\ Asking(op))
          /\ WF_vars(Import(Dst(op), op) /\ Asking(op))
          /\ WF_vars(RefuseConflict(Dst(op), op) /\ Asking(op))
          /\ WF_vars(RefuseEnded(Dst(op), op) /\ Asking(op))
    /\ WF_vars(QuorumBack)

(***************************************************************************)
(* Invariants.                                                             *)
(*                                                                         *)
(* OneOwner: the two orchestrators never serve the session together.       *)
(*                                                                         *)
(* ServeOnlyAsOwner: a node serves only while the record names it.         *)
(*                                                                         *)
(* OwnerHasNewest: the owner the record names holds the newest version,    *)
(* in its file or, between its activation and its import, in the copy     *)
(* that activation placed with it. No write is lost and no owner is left   *)
(* without the session.                                                    *)
(*                                                                         *)
(* MovingIsRemembered: a record that says moving has the row that says so  *)
(* on its owner, so a restart finds the move and resumes it.               *)
(*                                                                         *)
(* OneServingHolder: as in Move.tla, a node that serves holds the token.   *)
(***************************************************************************)
OneOwner == ~(serving["A"] /\ serving["B"])

ServeOnlyAsOwner == \A n \in Nodes : serving[n] => reg.owner = n

OwnerHasNewest ==
    \/ file[reg.owner] = top
    \/ /\ reg.st = "serving" /\ lastOp # 0 /\ Dst(lastOp) = reg.owner
       /\ copySt[lastOp] = "sent" /\ copyVer[lastOp] = top

MovingIsRemembered ==
    reg.st = "moving" =>
        /\ row[reg.owner] = "moving"
        /\ rowOp[reg.owner] = reg.op

OneServingHolder ==
    \A n \in Nodes : serving[n] => exec.holder # Other(n)

(***************************************************************************)
(* Liveness, under the fairness in Spec. MoveSettles: a record that says   *)
(* moving comes to say serving, under one owner or the other. MoverEnds:   *)
(* a node's moving row comes to say moved or resident, so no mover runs    *)
(* forever and no node is left unable to serve.                            *)
(***************************************************************************)
MoveSettles == (reg.st = "moving") ~> (reg.st = "serving")

MoverEnds == \A n \in Nodes : (row[n] = "moving") ~> (row[n] # "moving")

(***************************************************************************)
(* OwnerCanServe: whoever the record names as serving comes to hold the    *)
(* session in a row that lets it serve. It fails when an owner is left     *)
(* without the session it owns, as when a receiver's import is never       *)
(* finished because nobody asks it again.                                  *)
(***************************************************************************)
OwnerCanServe == (reg.st = "serving") ~> Allows(reg.owner)

=========================================================================
