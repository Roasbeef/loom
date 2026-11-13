---------------------------- MODULE MoveCheckout ----------------------------
(***************************************************************************)
(* The checkout step of `sessions.move` (protocol-change/107, slice 4c),   *)
(* composed with Move.tla.                                                 *)
(*                                                                         *)
(* A session that works in a directory on the source (A) has no executor   *)
(* scope to hand over. After the stop and before the close, the source     *)
(* captures the directory, sends the state to the executor, attaches a     *)
(* scope there, issues one fenced StateApply, closes the scope, and        *)
(* records its progress in the session file. Move.tla then continues as    *)
(* for any session on that executor.                                       *)
(*                                                                         *)
(* This module EXTENDS Move and reuses its actions unchanged, each wrapped *)
(* so that it leaves the checkout variables alone, except where a rule     *)
(* below says otherwise:                                                   *)
(*                                                                         *)
(*   - Cut and Send need the checkout recorded as done (CkMark).           *)
(*   - Intend starts a new attempt. StopA runs only to stop a serving      *)
(*     runtime, because a local session has no scope to close.             *)
(*   - A's own attach and open of the executor scope (AttachExec("A"),     *)
(*     OpenA) are replaced by OpenALocal: a local session serves from the  *)
(*     directory and holds no scope.                                       *)
(*   - AbortEarly and RefuseActivate also reset the mover's memory.        *)
(*   - The crashes of A also reset the mover's memory.                     *)
(*                                                                         *)
(* The step sits between Move's StopA and Cut. It writes no Move variable  *)
(* except `exec` (the scope it attaches and closes, in the same ledger     *)
(* rule Move uses), so OneOwner, which reads only servingA and servingB,   *)
(* cannot be affected by it, and the other Move invariants are checked in  *)
(* the composite configuration.                                            *)
(*                                                                         *)
(* The directory is a git repository: a commit store with parents, a HEAD  *)
(* and a working tree that is clean or holds an edit. `holds_tip`, the     *)
(* rule by which the executor treats an apply as already done, is          *)
(* HoldsRule. "ancestry" is the shipped rule (the tip is an ancestor of    *)
(* the tree's HEAD, `state_apply.holds_tip`). "applied" is the rule that   *)
(* the checkout needs: the tree holds the tip, or the last apply for the   *)
(* session was of this tip.                                                *)
(***************************************************************************)
EXTENDS Move, Integers

CONSTANTS
    HoldsRule,           \* "ancestry" (the earlier code) or "applied" (the fix in state_apply).
    BaseAhead,           \* The executor workspace's base is ahead of the laptop's HEAD.
    CellChecksOp,        \* A cell is believed only for the move that wrote it.
    FenceApply,          \* The executor judges the fence before it applies.
    CaptureLeavesLaptop, \* MUTANT: the capture commits the snapshot into the laptop's repository.
    OperatorAbandon,     \* An abandon may arrive while the scope is open (a directory member's).
    MaxEdits,            \* Bound on the operator's changes to the directory.
    MaxCommits,          \* Bound on commits made after the three initial ones.
    MaxAtt,              \* Bound on move attempts.
    MaxTok,              \* Bound on attach tokens.
    MaxReruns,           \* Bound on re-entries of the step without a crash.
    MaxLost,             \* Bound on lost replies to StateApply.
    InitWs,              \* The configured checkout_workspace may start as any of these.
    RebindClosedUnused,  \* An attach rebinds a closed scope that has no tree record.
    CloseFailedAttach,   \* An attach that cannot build its plane closes the scope it opened.
    MismatchRefused,     \* An attach refused for its workspace is a final refusal.
    RebindOpen           \* MUTANT: an attach also rebinds an open scope.

VARIABLES
    cfgWs, bound, reb,   \* The configured workspace; the scope's workspace; an open scope was rebound.
    par, cnt, nc,        \* The commit store: parent, content and the next id.
    head, wt, nw,        \* The laptop's HEAD, its working tree's content, the next edit.
    edits, opView,       \* Operator changes so far; what the operator last left.
    att, stopWt,         \* The attempt number; the working tree at the attempt's start.
    cell,                \* The progress cell in the session file.
    srcStore, store,     \* The tips held by the source's store and by the executor's.
    exBranch, applied,   \* The branch loom/<session> on the executor; the last applied tip.
    tok, tokAtt,         \* The scope's attach token; the attempt that minted it.
    net, answers,        \* StateApply requests in flight; replies in flight.
    aliveX, lastLand,    \* The executor is up; how the last apply was admitted.
    reruns, lost,        \* Counters.
    pc, mtip, mtipAtt,   \* The mover's memory: its place, its state and whose it is.
    mreq, minc, mtok     \* The request it waits on and the scope it attached.

L == <<par, cnt, nc, head, wt, nw, edits, opView>>
X == <<srcStore, store, exBranch, applied, tok, tokAtt, net, answers, aliveX, lastLand>>
H0 == <<att, stopWt, cell, reruns, lost>>
H == <<H0, cfgWs, bound, reb>>
M == <<pc, mtip, mtipAtt, mreq, minc, mtok>>
X1 == <<srcStore, store, exBranch, applied, tok, tokAtt, net, aliveX, lastLand>>
M2 == <<mtip, mtipAtt, mreq, minc, mtok>>
ext == <<L, X, H, M>>
allv == <<vars, ext>>

(***************************************************************************)
(* The commit store. Ids 0..2 exist at the start: 0 is the laptop's HEAD,  *)
(* 1 is a child of 0 (what an executor that is ahead holds), and 2 is an   *)
(* unrelated root. A content is a number; a commit's content is cnt[c].    *)
(* New commits are made by the operator and by a capture of a dirty tree.  *)
(***************************************************************************)
NC == 2 + MaxCommits
Base == IF BaseAhead THEN 1 ELSE 2
NoReq == [inc |-> -1, tok |-> -1, tip |-> -1, att |-> -1]

RECURSIVE Anc(_, _, _)
Anc(x, y, n) ==
    IF x = y THEN TRUE
    ELSE IF n = 0 THEN FALSE
    ELSE IF par[y] = -1 THEN FALSE
    ELSE Anc(x, par[y], n - 1)

\* x is y or an ancestor of y.
IsAnc(x, y) == Anc(x, y, NC + 1)

TypeOK2 ==
    /\ head \in 0..NC /\ wt \in 0..(10 + MaxEdits)
    /\ att \in 0..MaxAtt
    /\ pc \in {"idle", "start", "captured", "recorded", "sent", "attached",
               "asked", "applied", "rejected", "closed", "refused", "marked",
               "failed"}
    /\ cell.ph \in {"none", "taken", "done"}
    /\ exBranch \in -1..NC

Init2 ==
    /\ Init
    /\ par = [c \in 0..NC |-> IF c = 1 THEN 0 ELSE -1]
    /\ cnt = [c \in 0..NC |-> IF c \in 0..2 THEN c ELSE -1]
    /\ nc = 3
    /\ head = 0 /\ wt = 0 /\ nw = 10 /\ edits = 0 /\ opView = <<0, 0>>
    /\ att = 0 /\ stopWt = 0
    /\ cell = [op |-> 0, ph |-> "none", tip |-> -1]
    /\ srcStore = {} /\ store = {}
    /\ exBranch = -1 /\ applied = -1
    /\ tok = 0 /\ tokAtt = 0 /\ net = {} /\ answers = {}
    /\ aliveX = TRUE /\ lastLand = [fenced |-> TRUE, own |-> TRUE]
    /\ reruns = 0 /\ lost = 0
    /\ cfgWs \in InitWs /\ bound = "none" /\ reb = FALSE
    /\ pc = "idle" /\ mtip = -1 /\ mtipAtt = 0 /\ mreq = NoReq
    /\ minc = 0 /\ mtok = 0

(***************************************************************************)
(* The operator. The directory changes only while the session is resident  *)
(* and no move runs, including between an abandon and a retry. An edit     *)
(* leaves the tree dirty with new content; a commit makes the edit a       *)
(* commit; a discard (`git checkout .`) restores HEAD's content; a reset   *)
(* (`git reset --hard HEAD~1`) moves HEAD to its parent. opView is what    *)
(* the operator left, so LaptopUntouched says that nothing else wrote.     *)
(***************************************************************************)
Quiet == a = "active" /\ mover = "idle"

OpEdit ==
    /\ Quiet /\ edits < MaxEdits
    /\ wt' = nw /\ nw' = nw + 1 /\ edits' = edits + 1
    /\ opView' = <<head, nw>>
    /\ UNCHANGED <<vars, par, cnt, nc, head, X, H, M>>

OpCommit ==
    /\ Quiet /\ edits < MaxEdits /\ nc <= NC /\ wt # cnt[head]
    /\ par' = [par EXCEPT ![nc] = head]
    /\ cnt' = [cnt EXCEPT ![nc] = wt]
    /\ head' = nc /\ nc' = nc + 1 /\ edits' = edits + 1
    /\ opView' = <<nc, wt>>
    /\ UNCHANGED <<vars, wt, nw, X, H, M>>

OpDiscard ==
    /\ Quiet /\ edits < MaxEdits /\ wt # cnt[head]
    /\ wt' = cnt[head] /\ edits' = edits + 1
    /\ opView' = <<head, cnt[head]>>
    /\ UNCHANGED <<vars, par, cnt, nc, head, nw, X, H, M>>

OpReset ==
    /\ Quiet /\ edits < MaxEdits /\ par[head] # -1
    /\ head' = par[head] /\ wt' = cnt[par[head]] /\ edits' = edits + 1
    /\ opView' = <<par[head], cnt[par[head]]>>
    /\ UNCHANGED <<vars, par, cnt, nc, nw, X, H, M>>

(* A serves a local session from the directory. It holds no executor scope. *)
OpenALocal ==
    /\ aliveA /\ a = "active" /\ mover = "idle" /\ ~servingA
    /\ servingA' = TRUE
    /\ UNCHANGED <<a, b, copy, exec, mover, servingB, aliveA, aliveB, replied,
                   everMoved, crashes, ext>>

(***************************************************************************)
(* The mover's memory is lost by a crash, by an abandon and by a step that *)
(* stalls and is run again. MReset says so.                                *)
(***************************************************************************)
MReset ==
    /\ pc' = "idle" /\ mtip' = -1 /\ mtipAtt' = 0 /\ mreq' = NoReq
    /\ minc' = 0 /\ mtok' = 0 /\ answers' = {}

(***************************************************************************)
(* The attempt. Intend starts attempt att + 1 and records the working tree *)
(* at that moment: from here the directory is quiet, so it is also what    *)
(* the capture will read.                                                  *)
(***************************************************************************)
Intend2 ==
    /\ att < MaxAtt
    /\ Intend
    /\ att' = att + 1 /\ stopWt' = wt
    /\ UNCHANGED <<L, srcStore, store, exBranch, applied, tok, tokAtt, net,
                   aliveX, lastLand, cell, reruns, lost, cfgWs, bound, reb, M,
                   answers>>

StopA2 ==
    /\ servingA
    /\ StopA
    /\ UNCHANGED ext

(* The step runs while A's mover waits, the slot is stopped and B has nothing. *)
CkOn == aliveA /\ mover = "run" /\ a = "moving" /\ ~servingA /\ b = "absent"

(***************************************************************************)
(* The step begins by reading the cell, `move_checkout.carry`. A cell is   *)
(* believed for the move that wrote it (CellChecksOp), and a `taken` cell  *)
(* is used again only while the source's store holds the state.            *)
(***************************************************************************)
Believed == cell.ph # "none" /\ (cell.op = att \/ ~CellChecksOp)

CkRead ==
    /\ CkOn /\ pc = "idle"
    /\ \/ /\ Believed /\ cell.ph = "done"
          /\ pc' = "marked" /\ mtip' = cell.tip /\ mtipAtt' = cell.op
       \/ /\ Believed /\ cell.ph = "taken" /\ cell.tip \in srcStore
          /\ pc' = "recorded" /\ mtip' = cell.tip /\ mtipAtt' = cell.op
       \/ /\ ~(Believed /\ (cell.ph = "done" \/ cell.tip \in srcStore))
          /\ pc' = "start" /\ UNCHANGED <<mtip, mtipAtt>>
    /\ UNCHANGED <<vars, L, X, H, mreq, minc, mtok>>

(***************************************************************************)
(* The capture reads the directory in full. A clean tree has HEAD as its   *)
(* tip. A dirty tree becomes a snapshot commit on top of HEAD, a new       *)
(* commit every time. The mutant also commits it into the laptop's HEAD.   *)
(***************************************************************************)
Clean == wt = cnt[head]
Tip == IF Clean THEN head ELSE nc

CkCapture ==
    /\ CkOn /\ pc = "start"
    /\ Clean \/ nc <= NC
    /\ IF Clean
          THEN UNCHANGED <<par, cnt, nc, head>>
          ELSE /\ par' = [par EXCEPT ![nc] = head]
               /\ cnt' = [cnt EXCEPT ![nc] = wt]
               /\ nc' = nc + 1
               /\ head' = IF CaptureLeavesLaptop THEN nc ELSE head
    /\ mtip' = Tip /\ mtipAtt' = att
    /\ srcStore' = srcStore \cup {Tip}
    /\ pc' = "captured"
    /\ UNCHANGED <<vars, wt, nw, edits, opView, store, exBranch, applied, tok,
                   tokAtt, net, answers, aliveX, lastLand, H, mreq, minc, mtok>>

(* The captured state is written to the cell, `move_checkout.captured`. *)
CkRecord ==
    /\ CkOn /\ pc = "captured"
    /\ cell' = [op |-> att, ph |-> "taken", tip |-> mtip]
    /\ pc' = "recorded"
    /\ UNCHANGED <<vars, L, X, att, stopWt, reruns, lost, cfgWs, bound, reb, mtip,
                   mtipAtt, mreq, minc, mtok>>

(* The state is sent whole to the executor's store, `state_transfer.send`. *)
CkSend ==
    /\ CkOn /\ pc = "recorded" /\ aliveX
    /\ store' = store \cup {mtip}
    /\ pc' = "sent"
    /\ UNCHANGED <<vars, L, H, M2, srcStore, exBranch, applied, tok, tokAtt,
                   net, answers, aliveX, lastLand>>

(***************************************************************************)
(* The attach for the landing. It is the executor ledger's rule as Move    *)
(* has it: an open scope rebinds to the claimant at its own incarnation; a *)
(* closed one reopens at the next. Every attach mints a token. The tree is *)
(* the one the executor makes: the first attach branches from the          *)
(* workspace's base, a reopen of a closed scope recreates the tree from    *)
(* the session's branch, and an open scope's tree is adopted.              *)
(***************************************************************************)
(***************************************************************************)
(* The ledger binds a scope to the first workspace an attach names, whether *)
(* or not that attach succeeds (`exec_ledger.same_workspace`), and refuses a *)
(* later attach that names another. The configured workspace is cfgWs: the *)
(* executor serves it ("good"), serves it in `shared` mode ("shared"), or   *)
(* does not serve the name ("unknown"). An attach that the ledger refuses   *)
(* for its workspace is reported as a string the mover cannot tell from a   *)
(* lost connection, so the move stalls: no action is enabled.              *)
(*                                                                         *)
(* The ruled rules, each a constant so that its mutation can be checked:  *)
(*                                                                         *)
(*   RebindClosedUnused: an attach that names another workspace rebinds a  *)
(*   scope that is closed and has no tree record (exBranch = -1, the tree   *)
(*   record made by the first successful attach of a `worktree` workspace). *)
(*   An open scope keeps its binding.                                      *)
(*                                                                         *)
(*   CloseFailedAttach: an attach that cannot build its plane closes the    *)
(*   scope it opened, so the next attach meets a closed scope.             *)
(*                                                                         *)
(*   MismatchRefused: an attach that the ledger refuses for its workspace, *)
(*   or for a name the executor does not serve, is a final refusal and the *)
(*   move is abandoned. Without it the refusal reads as a lost connection  *)
(*   and the move stalls.                                                  *)
(*                                                                         *)
(* RebindOpen is the mutant that lets an attach rebind an open scope too.  *)
(***************************************************************************)
AttachAllowed ==
    \/ bound \in {"none", cfgWs}
    \/ RebindClosedUnused /\ exec.holder = "none" /\ exBranch = -1
    \/ RebindOpen /\ exBranch = -1

\* The attach changes the workspace of a scope that is open.
Rebinds == exec.holder # "none" /\ bound \notin {"none", cfgWs}

CkAttach ==
    /\ CkOn /\ pc = "sent" /\ aliveX /\ tok < MaxTok
    /\ cfgWs # "unknown"
    /\ AttachAllowed
    /\ \/ /\ exec.holder # "none"
          /\ exec' = [exec EXCEPT !.holder = "A"]
       \/ /\ exec.holder = "none" /\ exec.inc < MaxInc
          /\ exec' = [inc |-> exec.inc + 1, holder |-> "A"]
    /\ tok' = tok + 1 /\ tokAtt' = att
    /\ exBranch' = IF exBranch = -1 /\ cfgWs = "good" THEN Base ELSE exBranch
    /\ bound' = cfgWs
    /\ reb' = (reb \/ Rebinds)
    /\ minc' = exec'.inc /\ mtok' = tok + 1
    /\ pc' = "attached"
    /\ UNCHANGED <<a, b, copy, mover, servingA, servingB, aliveA, aliveB,
                   replied, everMoved, crashes, L, H0, cfgWs, srcStore, store,
                   applied, net, answers, aliveX, lastLand, mtip, mtipAtt, mreq>>

(* The attach for a name the executor does not serve: the ledger binds a     *)
(* scope and the plane cannot be built. With CloseFailedAttach the source    *)
(* then closes the scope (CkCloseFailed) and the move is refused; without it *)
(* the scope stays open and the mover stalls.                                *)
CkAttachUnknown ==
    /\ CkOn /\ pc = "sent" /\ aliveX /\ tok < MaxTok
    /\ cfgWs = "unknown" /\ bound # "unknown"   \* A repeat changes nothing the mover holds.
    /\ AttachAllowed
    /\ \/ /\ exec.holder # "none"
          /\ exec' = [exec EXCEPT !.holder = "A"]
       \/ /\ exec.holder = "none" /\ exec.inc < MaxInc
          /\ exec' = [inc |-> exec.inc + 1, holder |-> "A"]
    /\ tok' = tok + 1 /\ tokAtt' = att
    /\ bound' = "unknown"
    /\ reb' = (reb \/ Rebinds)
    /\ pc' = IF CloseFailedAttach THEN "failed" ELSE "sent"
    /\ UNCHANGED <<a, b, copy, mover, servingA, servingB, aliveA, aliveB,
                   replied, everMoved, crashes, L, H0, cfgWs, srcStore, store,
                   exBranch, applied, net, answers, aliveX, lastLand, mtip,
                   mtipAtt, mreq, minc, mtok>>

(* The source closes the scope the failed attach opened, and the move ends. *)
CkCloseFailed ==
    /\ CkOn /\ pc = "failed" /\ aliveX
    /\ exec' = [exec EXCEPT !.holder = "none"]
    /\ pc' = "refused"
    /\ UNCHANGED <<a, b, copy, mover, servingA, servingB, aliveA, aliveB,
                   replied, everMoved, crashes, L, H, srcStore, store, exBranch,
                   applied, tok, tokAtt, net, answers, aliveX, lastLand, mtip,
                   mtipAtt, mreq, minc, mtok>>

(* The operator corrects the configuration and restarts the daemon: the    *)
(* mover's memory is lost and the file is read again at the next run.      *)
FixConfig ==
    /\ cfgWs # "good" /\ cfgWs' = "good"
    \* The operator fixes it once the move has settled or is stalled at the
    \* attach, not while a landing is under way. A daemon that dies in a landing
    \* is the case MoveCheckoutMutantCrashAfterFailedAttach records.
    /\ pc \in {"idle", "sent"}
    /\ MReset
    /\ UNCHANGED <<vars, L, X1, H0, bound, reb>>

(***************************************************************************)
(* One StateApply, under the scope's incarnation and token. The request    *)
(* goes into the network; the executor takes it whenever it is up.         *)
(***************************************************************************)
CkAsk ==
    /\ CkOn /\ pc = "attached"
    /\ LET r == [inc |-> minc, tok |-> mtok, tip |-> mtip, att |-> att]
       IN /\ net' = net \cup {r} /\ mreq' = r
    /\ pc' = "asked"
    /\ UNCHANGED <<vars, L, H, srcStore, store, exBranch, applied, tok, tokAtt,
                   answers, aliveX, lastLand, mtip, mtipAtt, minc, mtok>>

(* A reply was lost, or the executor lost the request: ask again. *)
CkResend ==
    /\ CkOn /\ pc = "asked"
    /\ mreq \notin net /\ \A e \in answers : e.req # mreq
    /\ net' = net \cup {mreq}
    /\ UNCHANGED <<vars, L, H, M, srcStore, store, exBranch, applied, tok,
                   tokAtt, answers, aliveX, lastLand>>

(***************************************************************************)
(* The executor's judgement of an apply. Fenced: the scope is open under   *)
(* this incarnation and this token, which the ledger checks first. The     *)
(* mutant FenceApply = FALSE admits any request while a scope is open.     *)
(*                                                                         *)
(* Held is `state_apply.holds_tip`: whether the tree is left alone. The    *)
(* tree is clean, because nothing else writes it. An apply that is not     *)
(* held moves the branch with `checkout -B`.                               *)
(***************************************************************************)
Fenced(r) == exec.holder = "A" /\ exec.inc = r.inc /\ tok = r.tok

Admit(r) == IF FenceApply THEN Fenced(r) ELSE exec.holder # "none"

Held(tip) ==
    IF HoldsRule = "ancestry"
       THEN IsAnc(tip, exBranch)
       ELSE exBranch = tip \/ applied = tip

ExApply ==
    \E r \in net :
        /\ aliveX
        /\ net' = net \ {r}
        /\ IF Admit(r)
              THEN IF bound = "shared"
                      THEN \* A state is applied only into a worktree workspace.
                           /\ answers' = answers \cup {[req |-> r, res |-> "refused"]}
                           /\ UNCHANGED <<exBranch, applied, lastLand>>
                      ELSE /\ exBranch' = IF Held(r.tip) THEN exBranch ELSE r.tip
                           \* The record of the last apply is written whether the
                           \* tree moved or already held the tip.
                           /\ applied' = r.tip
                           /\ answers' = answers \cup {[req |-> r, res |-> "ok"]}
                           /\ lastLand' = [fenced |-> Fenced(r),
                                           own |-> r.att = att /\ tokAtt = att]
              ELSE /\ answers' = answers \cup {[req |-> r, res |-> "stale"]}
                   /\ UNCHANGED <<exBranch, applied, lastLand>>
        /\ UNCHANGED <<vars, L, H, M, srcStore, store, tok, tokAtt, aliveX>>

(* The executor's final refusal of a request that passed the fence. *)
ExRefuse ==
    \E r \in net :
        /\ aliveX /\ Fenced(r)
        /\ net' = net \ {r}
        /\ answers' = answers \cup {[req |-> r, res |-> "refused"]}
        /\ UNCHANGED <<vars, L, H, M, srcStore, store, exBranch, applied, tok,
                       tokAtt, aliveX, lastLand>>

(* A reply is lost on its way to the source. *)
LoseAnswer ==
    /\ lost < MaxLost
    /\ \E e \in answers :
          /\ answers' = answers \ {e}
          /\ lost' = lost + 1
    /\ UNCHANGED <<vars, L, X1, att, stopWt, cell, reruns, cfgWs, bound, reb, M>>

(***************************************************************************)
(* The mover takes the reply to its request: applied, refused by the       *)
(* fence (the run ends, to be run again), or refused for good, after which *)
(* the scope is closed and the move abandoned.                             *)
(***************************************************************************)
CkReceive ==
    /\ CkOn /\ pc = "asked"
    /\ \E e \in answers :
          /\ e.req = mreq
          /\ \/ /\ e.res = "ok"
                /\ pc' = "applied" /\ answers' = answers \ {e}
                /\ UNCHANGED <<mtip, mtipAtt, mreq, minc, mtok>>
             \/ /\ e.res = "stale"
                /\ MReset
             \/ /\ e.res = "refused"
                /\ pc' = "rejected" /\ answers' = answers \ {e}
                /\ UNCHANGED <<mtip, mtipAtt, mreq, minc, mtok>>
    /\ UNCHANGED <<vars, L, H, srcStore, store, exBranch, applied, tok, tokAtt,
                   net, aliveX, lastLand>>

(***************************************************************************)
(* The scope is closed on every path, applied or refused. A close under a  *)
(* token that has been replaced closes nothing, and the run ends.          *)
(***************************************************************************)
CkClose ==
    /\ CkOn /\ pc \in {"applied", "rejected"} /\ aliveX
    /\ \/ /\ exec.holder = "A" /\ exec.inc = minc /\ tok = mtok
          /\ exec' = [exec EXCEPT !.holder = "none"]
          /\ pc' = IF pc = "applied" THEN "closed" ELSE "refused"
          /\ UNCHANGED <<mtip, mtipAtt, mreq, minc, mtok, answers>>
       \/ /\ ~(exec.holder = "A" /\ exec.inc = minc /\ tok = mtok)
          /\ MReset
          /\ UNCHANGED exec
    /\ UNCHANGED <<a, b, copy, mover, servingA, servingB, aliveA, aliveB,
                   replied, everMoved, crashes, L, H, srcStore, store,
                   exBranch, applied, tok, tokAtt, net, aliveX, lastLand>>

(* The checkout is recorded as done, which lets the cut run. *)
CkMark ==
    /\ CkOn /\ pc = "closed"
    /\ cell' = [op |-> att, ph |-> "done", tip |-> mtip]
    /\ pc' = "marked"
    /\ UNCHANGED <<vars, L, X, att, stopWt, reruns, lost, cfgWs, bound, reb, mtip,
                   mtipAtt, mreq, minc, mtok>>

(***************************************************************************)
(* A step that cannot finish stalls and is run again from what is on disk. *)
(* `landing` closes the scope it attached on every path that returns, so a *)
(* rerun from inside a landing closes it, and needs the executor to be up. *)
(* A request it sent runs on. A daemon that dies in a landing closes       *)
(* nothing, which is CrashA2.                                              *)
(***************************************************************************)
InLanding == pc \in {"attached", "asked", "applied", "rejected", "failed"}

CkRerun ==
    /\ CkOn /\ pc \notin {"idle", "marked"} /\ reruns < MaxReruns
    /\ InLanding => aliveX
    /\ exec' = IF InLanding /\ exec.holder = "A"
                     /\ (pc = "failed" \/ (exec.inc = minc /\ tok = mtok))
                  THEN [exec EXCEPT !.holder = "none"]
                  ELSE exec
    /\ MReset
    /\ reruns' = reruns + 1
    /\ UNCHANGED <<a, b, copy, mover, servingA, servingB, aliveA, aliveB,
                   replied, everMoved, crashes, L, X1, att, stopWt, cell, lost,
                   cfgWs, bound, reb>>

(***************************************************************************)
(* Abandons. In the shipped code a local session's move is abandoned on a  *)
(* refusal, which comes at three places of the step: the capture is        *)
(* refused, the executor's store declines the state, or the apply is       *)
(* refused (after which the scope is closed). Later refusals are Move's    *)
(* AbortEarly and RefuseActivate, wrapped below. Nothing durable is        *)
(* undone: the cell, the stores and the branch stay.                       *)
(***************************************************************************)
AbandonWith(cond) ==
    /\ aliveA /\ mover = "run" /\ a = "moving" /\ copy = "none" /\ cond
    /\ a' = "active" /\ mover' = "idle" /\ replied' = FALSE
    /\ MReset
    /\ UNCHANGED <<b, copy, exec, servingA, servingB, aliveA, aliveB,
                   everMoved, crashes, L, X1, H>>

AbandonCapture == AbandonWith(pc = "start")

AbandonSend == AbandonWith(pc = "recorded" /\ mtip \notin store)

AbandonLanded == AbandonWith(pc = "refused")

(* An attach the ledger refuses for its workspace is final, and the move is  *)
(* abandoned with the reason.                                                *)
AbandonMismatch == MismatchRefused /\ AbandonWith(pc = "sent" /\ ~AttachAllowed)

(* A directory member's abandon, on request, whatever the step is doing. *)
AbandonAny == OperatorAbandon /\ AbandonWith(TRUE)

AbortEarly2 ==
    /\ OperatorAbandon \/ pc = "marked"
    /\ AbortEarly
    /\ MReset
    /\ UNCHANGED <<L, X1, H>>

RefuseActivate2 ==
    /\ RefuseActivate
    /\ MReset
    /\ UNCHANGED <<L, X1, H>>

(* The move's own steps wait for the checkout. *)
Cut2 ==
    /\ pc = "marked"
    /\ Cut
    /\ UNCHANGED ext

Send2 ==
    /\ pc = "marked"
    /\ Send
    /\ UNCHANGED ext

Activate2 == Activate /\ UNCHANGED ext
LoseReply2 == LoseReply /\ UNCHANGED ext
Retire2 == Retire /\ MReset /\ UNCHANGED <<L, X1, H>>
OpenB2 == OpenB /\ UNCHANGED ext

(* B's attach is a fenced event too: it mints a token. *)
AttachB2 ==
    /\ AttachExec("B") /\ aliveX /\ tok < MaxTok
    /\ tok' = tok + 1 /\ tokAtt' = att
    /\ UNCHANGED <<L, H, M, srcStore, store, exBranch, applied, net, answers,
                   aliveX, lastLand>>

(***************************************************************************)
(* Crashes. A's crash loses the mover's memory. The executor's crash loses *)
(* the requests it has not run and keeps its ledger, store and branch. All *)
(* three draw on the one bound.                                            *)
(***************************************************************************)
CrashA2 ==
    /\ CrashA
    /\ MReset
    /\ UNCHANGED <<L, X1, H>>

CrashB2 == CrashB /\ UNCHANGED ext

CrashX ==
    /\ aliveX /\ crashes < MaxCrashes
    /\ aliveX' = FALSE /\ net' = {}
    /\ crashes' = crashes + 1
    /\ UNCHANGED <<a, b, copy, exec, mover, servingA, servingB, aliveA, aliveB,
                   replied, everMoved, L, H, M, srcStore, store, exBranch,
                   applied, tok, tokAtt, answers, lastLand>>

RestartX ==
    /\ ~aliveX
    /\ aliveX' = TRUE
    /\ UNCHANGED <<vars, L, H, M, srcStore, store, exBranch, applied, tok,
                   tokAtt, net, answers, lastLand>>

Restart2 == Restart /\ UNCHANGED ext

Next2 ==
    \/ OpEdit \/ OpCommit \/ OpDiscard \/ OpReset \/ OpenALocal
    \/ Intend2 \/ StopA2 \/ Cut2 \/ Send2 \/ Activate2 \/ LoseReply2
    \/ Retire2 \/ AbortEarly2 \/ RefuseActivate2 \/ AttachB2 \/ OpenB2
    \/ CrashA2 \/ CrashB2 \/ Restart2 \/ CrashX \/ RestartX
    \/ CkRead \/ CkCapture \/ CkRecord \/ CkSend \/ CkAttach \/ CkAttachUnknown \/ CkCloseFailed
    \/ FixConfig \/ CkAsk
    \/ CkResend \/ ExApply \/ ExRefuse \/ LoseAnswer \/ CkReceive \/ CkClose
    \/ CkMark \/ CkRerun
    \/ AbandonCapture \/ AbandonSend \/ AbandonLanded \/ AbandonMismatch
    \/ AbandonAny

(***************************************************************************)
(* Fairness. The step's own actions, Move's protocol steps and the         *)
(* restarts happen when they stay enabled. Operator changes, lost replies, *)
(* reruns, refusals, abandons and crashes do not have to happen: the move  *)
(* must settle without them, and the faults are bounded.                   *)
(***************************************************************************)
Spec2 ==
    /\ Init2 /\ [][Next2]_allv
    /\ WF_allv(StopA2) /\ WF_allv(Cut2) /\ WF_allv(Send2)
    /\ WF_allv(Activate2) /\ WF_allv(Retire2) /\ WF_allv(Restart2)
    /\ WF_allv(RestartX)
    /\ WF_allv(CkRead) /\ WF_allv(CkCapture) /\ WF_allv(CkRecord)
    /\ WF_allv(CkSend) /\ WF_allv(CkAttach) /\ WF_allv(CkAsk)
    /\ WF_allv(CkResend) /\ WF_allv(ExApply) /\ WF_allv(CkReceive)
    /\ WF_allv(CkClose) /\ WF_allv(CkMark)
    /\ WF_allv(AbandonLanded) /\ WF_allv(FixConfig)
    /\ WF_allv(AbandonMismatch) /\ WF_allv(CkCloseFailed)

(***************************************************************************)
(* Properties.                                                             *)
(*                                                                         *)
(* CheckoutIsWhatWasStopped: once the destination owns the session, the    *)
(* executor's branch holds exactly the content the laptop directory had at *)
(* the start of that attempt: not an older snapshot of an abandoned        *)
(* attempt, not a tree the executor already had.                           *)
(*                                                                         *)
(* LaptopUntouched: the directory is as the operator last left it.         *)
(*                                                                         *)
(* NoApplyOutsideFence: an apply that changed the tree was admitted by the *)
(* fence, and the scope it was admitted under was opened by the current    *)
(* attempt.                                                                *)
(*                                                                         *)
(* AbandonRestores: after an abandon the laptop owns the session alone,    *)
(* and the mover never holds a state that another attempt captured.        *)
(*                                                                         *)
(* NoLeak: a settled move leaves no scope that the source attached.        *)
(***************************************************************************)
CheckoutIsWhatWasStopped ==
    (b = "active" \/ a = "moved") => (exBranch # -1 /\ cnt[exBranch] = stopWt)

LaptopUntouched == <<head, wt>> = opView

(* A scope that is open keeps the workspace it is bound to: the session that *)
(* works in it, in a `shared` workspace, never finds its scope moved.        *)
OpenScopeKeepsWorkspace == ~reb

NoApplyOutsideFence == lastLand.fenced /\ lastLand.own

AbandonRestores ==
    /\ a = "active" => b = "absent"
    /\ pc \notin {"idle", "start"} => mtipAtt = att
    \* A corrected configuration is not blocked by a scope that a failed
    \* attempt left bound to the workspace it named.
    /\ cfgWs = "good" => (AttachAllowed \/ exec.holder # "none")

NoLeak ==
    /\ (a = "active" /\ mover = "idle" /\ att > 0) => exec.holder # "A"
    /\ a = "moved" => exec.holder # "A"

(* Liveness: a move with a checkout step settles. *)
CheckoutSettles == (a = "moving") ~> (a \in {"moved", "active"})

(***************************************************************************)
(* Not a property of the shipped code, kept to say so: the cell is left in *)
(* the session file after the move settles, and names the finished         *)
(* attempt. A later attempt ignores it (CellChecksOp). The reachability    *)
(* check below uses this as a throwaway invariant.                         *)
(***************************************************************************)
CellNamesNoFinishedAttempt ==
    (a # "moving" /\ att > 0) => cell.ph = "none"

=============================================================================
