------------------------------ MODULE Claims ------------------------------
(***************************************************************************)
(* Pool placement claims (PR #1185). A session created in a pool picks its *)
(* executor when it first opens. The orchestrator orders the pool's        *)
(* executors by how many open scopes it has already placed on each, fewest *)
(* first, ties broken by the configured position (`pools.spread`). A       *)
(* session that is still being built has no open scope yet, so the         *)
(* registry keeps a claim for it, `Book.claims`, and adds one to the count *)
(* of the claimed executor for every other session whose slot is waiting   *)
(* or building (`manager.claim_placement`, `live_claims`, `held_by`).      *)
(*                                                                         *)
(* The model asks three things. Do concurrent first opens spread over the  *)
(* pool (Balanced)? Is every session that holds an executor, or is about   *)
(* to, counted exactly once when an open asks (ClaimCountedOnce)? Does a   *)
(* session that is no longer being built stop counting (NoLeakedClaim)?    *)
(*                                                                         *)
(* The code differs from its own description in one place that matters.    *)
(* The open scopes are counted by the caller, from the catalogue, before   *)
(* it calls the registry (`daemon/main.gleam`, the `claim` closure passes  *)
(* `ledger_holdings.resident_by_name(...)` as an argument), and only the   *)
(* claims are read inside the registry's turn. AtomicRead = FALSE is that  *)
(* shape. AtomicRead = TRUE counts the open scopes in the same turn as the *)
(* claims, which is what the doc comment of `claim_placement` says it      *)
(* does.                                                                   *)
(*                                                                         *)
(* Five constants turn a rule off so that its mutation can be checked.     *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    NExec,        \* The pool's executors, 1..NExec, in configured order.
    NSess,        \* Concurrent first opens, 1..NSess.
    AtomicRead,   \* The open scopes are counted in the registry's turn.
    OneTurn,      \* The count, the ordering and the record are one turn.
    CountsRunning, \* MUTANT: a claim keeps counting once its slot is running.
    FailureKeeps, \* MUTANT: a claim keeps counting once its builder failed.
    Down,         \* Executors that decline every attach, so a session lands on a later candidate.
    Bound,        \* The difference Balanced allows.
    MaxRetry,     \* Retries of a failed open, per session.
    MaxRestarts   \* Restarts of the registry.

Executors == 1..NExec
Up == Executors \ Down
Sessions == 1..NSess
None == 0

VARIABLES
    ph,       \* A session's phase: new, snapped, read, building, running or failed.
    claims,   \* Book.claims: the executor each session last claimed, or None.
    ord,      \* The order the registry answered a session with.
    att,      \* The executor on which a session's scope is open, or None.
    reg,      \* The executor the catalogue says a session is placed on, or None.
    snap,     \* The sessions that were resident when a session's open read them.
    retries,  \* Retries so far, per session.
    restarts, \* Registry restarts so far.
    removed,  \* History: a built session failed or the registry restarted.
    viol      \* History: an ask counted a session other than exactly once.

vars == <<ph, claims, ord, att, reg, snap, retries, restarts, removed, viol>>

(***************************************************************************)
(* The count of an executor as the registry sees it when `asker` asks: the *)
(* resident sessions on it, plus a claim for each other session whose slot *)
(* the registry still counts. Resident means the slot is running and the   *)
(* catalogue names the executor. With AtomicRead the registry reads that   *)
(* set in its own turn. Otherwise the set is what the caller read earlier, *)
(* `snap[asker]`.                                                          *)
(*                                                                         *)
(* The slot filter is `live_claims`: waiting or building. CountsRunning    *)
(* also keeps running slots, and FailureKeeps also keeps failed ones.      *)
(***************************************************************************)
RunningNow == {s \in Sessions : ph[s] = "running"}

Resident(asker) == IF AtomicRead THEN RunningNow ELSE snap[asker]

Keeps(p) ==
    \/ p = "building"
    \/ CountsRunning /\ p = "running"
    \/ FailureKeeps /\ p = "failed"

Counted(s) == claims[s] # None /\ Keeps(ph[s])

Held(asker, e) ==
    Cardinality({s \in Resident(asker) : reg[s] = e})
    + Cardinality({s \in Sessions \ {asker} : Counted(s) /\ claims[s] = e})

Pos == [e \in Executors |-> e]

\* The executors in the order `pools.spread` gives: fewest first, the
\* configured position among equals. Keys are distinct, so one sequence fits.
Perms == {q \in [1..NExec -> Executors] :
             \A i, j \in 1..NExec : i # j => q[i] # q[j]}

Order(asker) ==
    CHOOSE q \in Perms :
        \A i, j \in 1..NExec :
            i < j =>
              \/ Held(asker, q[i]) < Held(asker, q[j])
              \/ Held(asker, q[i]) = Held(asker, q[j]) /\ q[i] < q[j]

TypeOK ==
    /\ ph \in [Sessions -> {"new", "snapped", "read", "building", "running", "failed"}]
    /\ claims \in [Sessions -> 0..NExec]
    /\ att \in [Sessions -> 0..NExec]
    /\ reg \in [Sessions -> 0..NExec]

Init ==
    /\ ph = [s \in Sessions |-> "new"]
    /\ claims = [s \in Sessions |-> None]
    /\ ord = [s \in Sessions |-> <<>>]
    /\ att = [s \in Sessions |-> None]
    /\ reg = [s \in Sessions |-> None]
    /\ snap = [s \in Sessions |-> {}]
    /\ retries = [s \in Sessions |-> 0]
    /\ restarts = 0
    /\ removed = FALSE
    /\ viol = FALSE

(***************************************************************************)
(* The caller reads the resident counts from the catalogue. This is a      *)
(* separate step from the registry's turn unless AtomicRead.               *)
(***************************************************************************)
Snap(x) ==
    /\ ~AtomicRead /\ ph[x] = "new"
    /\ ph' = [ph EXCEPT ![x] = "snapped"]
    /\ snap' = [snap EXCEPT ![x] = RunningNow]
    /\ UNCHANGED <<claims, ord, att, reg, retries, restarts, removed, viol>>

(***************************************************************************)
(* The registry's turn: count, order and, when OneTurn, record the head as *)
(* the session's claim. Every other session that holds an executor or is   *)
(* about to must be counted once, by its resident row or by its claim: viol *)
(* remembers an ask that counted one of them twice or not at all. Without  *)
(* OneTurn the turn answers and the record is another step.                *)
(***************************************************************************)
Times(asker, s) ==
    (IF s \in Resident(asker) THEN 1 ELSE 0)
    + (IF Counted(s) THEN 1 ELSE 0)

Turn(x) ==
    /\ \/ AtomicRead /\ ph[x] = "new"
       \/ ~AtomicRead /\ ph[x] = "snapped"
    /\ LET q == Order(x)
       IN /\ ord' = [ord EXCEPT ![x] = q]
          /\ IF OneTurn
                THEN /\ ph' = [ph EXCEPT ![x] = "building"]
                     /\ claims' = [claims EXCEPT ![x] = q[1]]
                ELSE /\ ph' = [ph EXCEPT ![x] = "read"]
                     /\ UNCHANGED claims
    /\ viol' = (viol \/ (\E s \in Sessions \ {x} :
                  ph[s] \in {"building", "running"} /\ Times(x, s) # 1))
    /\ UNCHANGED <<att, reg, snap, retries, restarts, removed>>

(* The separate record of the mutant that does not read and record at once. *)
Record(x) ==
    /\ ph[x] = "read"
    /\ ph' = [ph EXCEPT ![x] = "building"]
    /\ claims' = [claims EXCEPT ![x] = ord[x][1]]
    /\ UNCHANGED <<ord, att, reg, snap, retries, restarts, removed, viol>>

(***************************************************************************)
(* The builder attaches to the first candidate that takes the scope. The   *)
(* attach skips a candidate that is down or full (the executors of Down,   *)
(* which decline every attach), and tells the registry which executor took *)
(* it (`seed_executor`), which points the session's claim there.           *)
(***************************************************************************)
Attach(x, i) ==
    /\ ph[x] = "building" /\ att[x] = None
    /\ \A j \in 1..(i - 1) : ord[x][j] \in Down
    /\ ord[x][i] \notin Down
    /\ att' = [att EXCEPT ![x] = ord[x][i]]
    /\ reg' = [reg EXCEPT ![x] = ord[x][i]]
    /\ claims' = [claims EXCEPT ![x] = ord[x][i]]
    /\ UNCHANGED <<ph, ord, snap, retries, restarts, removed, viol>>

(* The slot becomes resident: the claim stops counting and the row counts. *)
Finish(x) ==
    /\ ph[x] = "building" /\ att[x] # None
    /\ ph' = [ph EXCEPT ![x] = "running"]
    /\ UNCHANGED <<claims, ord, att, reg, snap, retries, restarts, removed, viol>>

(* The builder fails before the slot is resident. Its scope, if any, closes. *)
Fail(x) ==
    /\ ph[x] = "building"
    /\ ph' = [ph EXCEPT ![x] = "failed"]
    /\ att' = [att EXCEPT ![x] = None]
    /\ removed' = TRUE
    /\ UNCHANGED <<claims, ord, reg, snap, retries, restarts, viol>>

(* The open is asked for again. Its old claim entry stays until it is replaced. *)
Retry(x) ==
    /\ ph[x] = "failed" /\ retries[x] < MaxRetry
    /\ ph' = [ph EXCEPT ![x] = "new"]
    /\ retries' = [retries EXCEPT ![x] = @ + 1]
    /\ UNCHANGED <<claims, ord, att, reg, snap, restarts, removed, viol>>

(***************************************************************************)
(* A restart of the registry loses its memory, the claims included, and    *)
(* with it every slot: sessions are saved again, their scopes close, and   *)
(* opens are asked for again.                                              *)
(***************************************************************************)
Restart ==
    /\ restarts < MaxRestarts
    /\ restarts' = restarts + 1
    /\ ph' = [s \in Sessions |-> "new"]
    /\ claims' = [s \in Sessions |-> None]
    /\ att' = [s \in Sessions |-> None]
    /\ snap' = [s \in Sessions |-> {}]
    /\ removed' = TRUE
    /\ UNCHANGED <<ord, reg, retries, viol>>

Next ==
    \/ \E x \in Sessions : Snap(x) \/ Turn(x) \/ Record(x) \/ Finish(x)
                           \/ Fail(x) \/ Retry(x)
    \/ \E x \in Sessions, i \in 1..NExec : Attach(x, i)
    \/ Restart

Spec ==
    /\ Init /\ [][Next]_vars
    /\ \A x \in Sessions :
          /\ WF_vars(Snap(x)) /\ WF_vars(Turn(x)) /\ WF_vars(Record(x))
          /\ WF_vars(\E i \in 1..NExec : Attach(x, i)) /\ WF_vars(Finish(x))

(***************************************************************************)
(* Properties.                                                             *)
(*                                                                         *)
(* True counts. Occupancy(e) is what the registry's count should be: the   *)
(* running sessions on e, and the building ones that have claimed e. The   *)
(* perceived count is what a new ask would see with the read made now.     *)
(*                                                                         *)
(* Balanced: when nothing has failed and the registry has not restarted,   *)
(* the number of claims plus open scopes on any two executors differs by   *)
(* at most Bound. The code's guarantee is Bound = 1 when the opens count   *)
(* each session once and the attach takes the first candidate.             *)
(*                                                                         *)
(* ClaimCountedOnce: each time an open asks, every other session that      *)
(* holds an executor or is about to is counted exactly once, by its        *)
(* resident row or its claim, never both and never neither.                *)
(*                                                                         *)
(* NoLeakedClaim: no executor is counted as holding more than it holds. A  *)
(* builder that failed, a slot that is resident, and a registry that       *)
(* restarted leave no claim that counts.                                   *)
(***************************************************************************)
Occupancy(e) ==
    Cardinality({s \in Sessions : ph[s] = "running" /\ reg[s] = e})
    + Cardinality({s \in Sessions : ph[s] = "building" /\ claims[s] = e})

Perceived(e) ==
    Cardinality({s \in RunningNow : reg[s] = e})
    + Cardinality({s \in Sessions : Counted(s) /\ claims[s] = e})

Balanced ==
    ~removed =>
        \A e1, e2 \in Up : Occupancy(e1) <= Occupancy(e2) + Bound

ClaimCountedOnce == ~viol

NoLeakedClaim == \A e \in Executors : Perceived(e) <= Occupancy(e)

(* Liveness: an open that is asked for comes to run or to fail. The      *)
(* sessions are interchangeable, so it is stated for the first.           *)
OpensSettle ==
    ph[1] = "new" ~> ph[1] \in {"running", "failed"}

=============================================================================
