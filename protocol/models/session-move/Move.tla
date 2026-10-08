------------------------------ MODULE Move ------------------------------
(***************************************************************************)
(* One controlled move of a session from orchestrator A (the source) to    *)
(* orchestrator B (the target), with one executor between them. It is the  *)
(* model for phase 5 of issue #697. The protocol it checks is the six      *)
(* steps in the phase 5 design: intend and stop, clean close, cut, send,   *)
(* activate, retire.                                                       *)
(*                                                                         *)
(* The model asks one question: can a crash, a lost reply or an abort      *)
(* leave two orchestrators serving the session, or leave no complete copy  *)
(* of it? It does not model the data in the copy, the directory lookups    *)
(* (phase 3), or more than one move at a time.                             *)
(*                                                                         *)
(* Three constants switch a rule off so that its mutation can be checked.  *)
(* A clean run sets all three to TRUE. Each Mutant*.cfg sets one to FALSE  *)
(* and names the invariant the checker must then violate.                  *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    IntendDurable,   \* Intend writes the `moving` row before anything else.
    AbortGuardsSent, \* AbortEarly is refused once the copy is on B.
    RetireObserves,  \* Retire needs to have seen B's row active.
    MaxInc,          \* Bound on the executor incarnation.
    MaxCrashes       \* Bound on crashes of either node in one behaviour.

VARIABLES
    a,         \* A's catalogue row: "active", "moving" or "moved".
    b,         \* B's catalogue row: "absent" or "active".
    copy,      \* The transfer file: "none", "cut" (on A) or "sent" (on B).
    exec,      \* The executor ledger row for the session.
    mover,     \* A's in-memory mover task: "idle" or "run".
    servingA,  \* A has a runtime serving the session.
    servingB,  \* B has a runtime serving the session.
    aliveA,    \* A's process is up.
    aliveB,    \* B's process is up.
    replied,   \* A holds B's reply to Activate.
    everMoved, \* History: A has retired the session at some point.
    crashes    \* Crashes so far, of either node.

vars == <<a, b, copy, exec, mover, servingA, servingB, aliveA, aliveB,
          replied, everMoved, crashes>>

(***************************************************************************)
(* The executor ledger row is [inc, holder]. A holder of "none" stands for *)
(* a scope that is closed, or has never been attached; "A" or "B" is an    *)
(* open scope whose attach token the named node holds. The checked rule is *)
(* `attach_existing` in packages/storage/src/storage/exec_ledger.gleam:    *)
(* an open scope accepts a claim of its own incarnation and rebinds the    *)
(* token to the claimant, whoever held it before; a closed scope accepts   *)
(* only incarnation + 1 and reopens at that number. A node's claim comes   *)
(* from its cached copy of the cell, which can be stale, so the model lets *)
(* a node claim either number and lets the ledger decide.                  *)
(***************************************************************************)
Holders == {"none", "A", "B"}

TypeOK ==
    /\ a \in {"active", "moving", "moved"}
    /\ b \in {"absent", "active"}
    /\ copy \in {"none", "cut", "sent"}
    /\ exec \in [inc : 0..MaxInc, holder : Holders]
    /\ mover \in {"idle", "run"}
    /\ {servingA, servingB, aliveA, aliveB, replied, everMoved} \subseteq BOOLEAN
    /\ crashes \in 0..MaxCrashes

Init ==
    /\ a = "active"
    /\ b = "absent"
    /\ copy = "none"
    /\ exec = [inc |-> 0, holder |-> "none"]
    /\ mover = "idle"
    /\ servingA = FALSE
    /\ servingB = FALSE
    /\ aliveA = TRUE
    /\ aliveB = TRUE
    /\ replied = FALSE
    /\ everMoved = FALSE
    /\ crashes = 0

(***************************************************************************)
(* Step 1. The mover starts. With IntendDurable the `moving` row is        *)
(* committed in the same step, so every later restart of A finds it. The   *)
(* mutant keeps the intent in the mover's memory only. The node refuses    *)
(* new opens while the mover runs, which is the in-memory half of slot     *)
(* admission (OpenA).                                                      *)
(***************************************************************************)
Intend ==
    /\ aliveA /\ a = "active" /\ mover = "idle"
    /\ a' = IF IntendDurable THEN "moving" ELSE "active"
    /\ mover' = "run"
    /\ UNCHANGED <<b, copy, exec, servingA, servingB, aliveA, aliveB,
                   replied, everMoved, crashes>>

(***************************************************************************)
(* Steps 1 and 2. The slot stops and A closes the executor scope cleanly,  *)
(* releasing the token it holds. Neither is needed once both are done.     *)
(***************************************************************************)
StopA ==
    /\ aliveA /\ mover = "run"
    /\ servingA \/ exec.holder = "A"
    /\ servingA' = FALSE
    /\ exec' = [exec EXCEPT !.holder = IF @ = "A" THEN "none" ELSE @]
    /\ UNCHANGED <<a, b, copy, mover, servingB, aliveA, aliveB, replied,
                   everMoved, crashes>>

(***************************************************************************)
(* Step 3. The cut reads the closed scope, so it needs the stop to have    *)
(* finished and the scope to be closed.                                    *)
(***************************************************************************)
Cut ==
    /\ aliveA /\ mover = "run" /\ copy = "none"
    /\ ~servingA /\ exec.holder = "none"
    /\ copy' = "cut"
    /\ UNCHANGED <<a, b, exec, mover, servingA, servingB, aliveA, aliveB,
                   replied, everMoved, crashes>>

(* Step 4. The whole file arrives on B. *)
Send ==
    /\ aliveA /\ mover = "run" /\ copy = "cut"
    /\ copy' = "sent"
    /\ UNCHANGED <<a, b, exec, mover, servingA, servingB, aliveA, aliveB,
                   replied, everMoved, crashes>>

(***************************************************************************)
(* Step 5. B's row goes from absent to active in one local write. The      *)
(* reply reaches A only if A is up and its mover is waiting.               *)
(***************************************************************************)
Activate ==
    /\ aliveB /\ b = "absent" /\ copy = "sent"
    /\ b' = "active"
    /\ replied' = (aliveA /\ mover = "run")
    /\ UNCHANGED <<a, copy, exec, mover, servingA, servingB, aliveA, aliveB,
                   everMoved, crashes>>

(* The reply to Activate is dropped, or A did not wait for it. *)
LoseReply ==
    /\ replied
    /\ replied' = FALSE
    /\ UNCHANGED <<a, b, copy, exec, mover, servingA, servingB, aliveA,
                   aliveB, everMoved, crashes>>

(***************************************************************************)
(* Step 6. A retires the session. The observation of B's row is the reply  *)
(* when A holds one and otherwise a status query, which needs B up. The    *)
(* mutant retires as soon as the file is sent.                             *)
(***************************************************************************)
Retire ==
    /\ aliveA /\ mover = "run"
    /\ IF RetireObserves
          THEN b = "active" /\ (replied \/ aliveB)
          ELSE copy = "sent"
    /\ a' = "moved"
    /\ mover' = "idle"
    /\ replied' = FALSE
    /\ everMoved' = TRUE
    /\ UNCHANGED <<b, copy, exec, servingA, servingB, aliveA, aliveB,
                   crashes>>

(***************************************************************************)
(* The only way back. A cut that never left A is reaped; a copy already on *)
(* B stays there. The mutant allows the abort after the send.              *)
(***************************************************************************)
AbortEarly ==
    /\ aliveA /\ mover = "run" /\ a # "moved"
    /\ copy # "sent" \/ ~AbortGuardsSent
    /\ a' = "active"
    /\ mover' = "idle"
    /\ copy' = IF copy = "sent" THEN "sent" ELSE "none"
    /\ replied' = FALSE
    /\ UNCHANGED <<b, exec, servingA, servingB, aliveA, aliveB, everMoved,
                   crashes>>

(***************************************************************************)
(* The executor attach. A node may attach only where its own row lets it   *)
(* serve, and the ledger then applies the rule described above.            *)
(***************************************************************************)
AttachExec(n) ==
    /\ IF n = "A"
          THEN aliveA /\ a = "active" /\ mover = "idle"
          ELSE aliveB /\ b = "active"
    /\ \/ /\ exec.holder # "none"
          /\ exec' = [exec EXCEPT !.holder = n]
       \/ /\ exec.holder = "none" /\ exec.inc < MaxInc
          /\ exec' = [inc |-> exec.inc + 1, holder |-> n]
    /\ UNCHANGED <<a, b, copy, mover, servingA, servingB, aliveA, aliveB,
                   replied, everMoved, crashes>>

(***************************************************************************)
(* A runtime starts serving. It needs its node's row to allow it and the   *)
(* node to hold the executor token. A refuses while its mover runs.        *)
(***************************************************************************)
OpenA ==
    /\ aliveA /\ a = "active" /\ mover = "idle"
    /\ exec.holder = "A" /\ ~servingA
    /\ servingA' = TRUE
    /\ UNCHANGED <<a, b, copy, exec, mover, servingB, aliveA, aliveB,
                   replied, everMoved, crashes>>

OpenB ==
    /\ aliveB /\ b = "active"
    /\ exec.holder = "B" /\ ~servingB
    /\ servingB' = TRUE
    /\ UNCHANGED <<a, b, copy, exec, mover, servingA, aliveA, aliveB,
                   replied, everMoved, crashes>>

(***************************************************************************)
(* A crash drops everything in memory and keeps every row, the copy and    *)
(* the executor ledger. A restart of A respawns the mover only for a       *)
(* `moving` row.                                                           *)
(***************************************************************************)
CrashA ==
    /\ aliveA /\ crashes < MaxCrashes
    /\ aliveA' = FALSE /\ servingA' = FALSE /\ mover' = "idle"
    /\ replied' = FALSE
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<a, b, copy, exec, servingB, aliveB, everMoved>>

CrashB ==
    /\ aliveB /\ crashes < MaxCrashes
    /\ aliveB' = FALSE /\ servingB' = FALSE
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<a, b, copy, exec, mover, servingA, aliveA, replied,
                   everMoved>>

Restart ==
    \/ /\ ~aliveA
       /\ aliveA' = TRUE
       /\ mover' = IF a = "moving" THEN "run" ELSE "idle"
       /\ UNCHANGED <<a, b, copy, exec, servingA, servingB, aliveB, replied,
                      everMoved, crashes>>
    \/ /\ ~aliveB
       /\ aliveB' = TRUE
       /\ UNCHANGED <<a, b, copy, exec, mover, servingA, servingB, aliveA,
                      replied, everMoved, crashes>>

Next ==
    \/ Intend \/ StopA \/ Cut \/ Send \/ Activate \/ LoseReply \/ Retire
    \/ AbortEarly
    \/ AttachExec("A") \/ AttachExec("B") \/ OpenA \/ OpenB
    \/ CrashA \/ CrashB \/ Restart

(***************************************************************************)
(* Fairness. Every step of the protocol and every restart eventually       *)
(* happens when it stays enabled. Crashes are bounded by MaxCrashes, so    *)
(* the environment cannot crash a node forever. LoseReply, AbortEarly and  *)
(* the opens are not fair: the protocol must finish without them.          *)
(***************************************************************************)
Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(StopA) /\ WF_vars(Cut) /\ WF_vars(Send)
    /\ WF_vars(Activate) /\ WF_vars(Retire) /\ WF_vars(Restart)

(***************************************************************************)
(* Invariants.                                                             *)
(*                                                                         *)
(* OneOwner: the two orchestrators never serve the session together.       *)
(*                                                                         *)
(* NoResurrection: once A has retired the session, A's row is moved and    *)
(* stays moved. No action leaves `moved`, and this says so.                *)
(*                                                                         *)
(* ActiveImpliesComplete: B's row is active only over the complete copy,   *)
(* and A retires only over an active row on B, so no state has a moved     *)
(* session without a complete owner.                                       *)
(*                                                                         *)
(* OneServingHolder: a runtime that serves the session holds the executor  *)
(* token, so the executor never fences the node that serves. The brief     *)
(* states the A half; the B half is the same rule from the other side.     *)
(***************************************************************************)
OneOwner == ~(servingA /\ servingB)

NoResurrection == everMoved => a = "moved"

ActiveImpliesComplete ==
    /\ b = "active" => copy = "sent"
    /\ a = "moved" => b = "active"

OneServingHolder ==
    /\ servingA => exec.holder # "B"
    /\ servingB => exec.holder # "A"

(* Liveness, under the fairness in Spec. *)
MoveSettles == (a = "moving") ~> (a \in {"moved", "active"})

=========================================================================
