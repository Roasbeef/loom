----------------------------- MODULE Admission -----------------------------
(***************************************************************************)
(* The admission of one seeded child on a pool that is full                *)
(* (protocol-change/107, slice 4b; issue #1137, exit criterion 3).         *)
(*                                                                         *)
(* A parent on the laptop asks the box for a child whose session is to be  *)
(* placed on an executor of a pool, and every executor of the pool is at   *)
(* its scope limit. Two askers ask for the same child at once, as in the   *)
(* code: the spawn tool (`agency.ask_until_answered`, a doubling pause)    *)
(* and the session's drain (`remote_drain.spawn_pass`, one ask per pass).  *)
(* The orchestrator port serves each ask in a process of its own, so on    *)
(* the box the two asks interleave at every registry turn.                 *)
(*                                                                         *)
(* On the box the child has a delegate row, a registration (reserved       *)
(* until its first build succeeds, saved after), a start failure the       *)
(* catalogue may keep, and a slot in the registry. An ask is one registry  *)
(* turn (`manager.delegate_session`) and then a poll of the session's      *)
(* status (`delegate_host.resident`). A build fails for want of room while *)
(* the pool is full and succeeds once a scope is free.                     *)
(*                                                                         *)
(* A scope frees only when a finished child is joined. While the parent    *)
(* waits in the spawn tool its own `agent_wait` cannot run, so the only    *)
(* joiner is the drain's join step, which runs after its spawn step in     *)
(* every pass (`remote_drain.pass`). The parent's own wait after the tool  *)
(* returns is not modelled: the property is about the asks.                *)
(*                                                                         *)
(* Four constants turn on the rules of the fix, and three more turn one    *)
(* rule into a wrong version of it, so that its mutation can be checked.   *)
(* All four rules off is the code the second drive ran (e128668ee).        *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    RetryInPlace,   \* R1: a repeat ask rebuilds the reservation; nothing ends a row for no room.
    BareAsksAgain,  \* R2: a reservation with no kept failure is a reason to ask again, not final.
    AnswerNotSilent,\* R3: a NotYetOpen answer to the drain's spawn does not skip its join.
    FinalReleases,  \* A final refusal ends the child's session (`ended_unless_asks_again`).
    RetryMakesNew,  \* MUTANT of R1: the repeat ask makes a new reservation instead.
    LostFailure,    \* The catalogue may fail to keep a start failure, once.
    MaxMade         \* Bound on registrations made, for the configurations that make many.

Askers == {"tool", "drain"}
None == 0

VARIABLES
    row,      \* The delegate row: "none", "open" or "releasing".
    sid,      \* The registration the row names, or None.
    regs,     \* Every registration that exists for this child (a leak is a second one).
    reg,      \* The state of the row's registration: "reserved" or "saved".
    kept,     \* The start failure the catalogue kept: "none", "noroom" or "lost".
    slot,     \* The registry's slot: "none", "building", "closing" or "running".
    made,     \* Registrations made so far.
    room,     \* An executor scope is free.
    finished, \* Another child of the parent has finished; its scope frees at its join.
    started,  \* The registrations in which a child was started (a first turn).
    ask,      \* Each asker: "idle", "poll", "ending" or "done".
    held,     \* The registration each asker was admitted to.
    stub,     \* The parent's stub: "requested", "refused" or "spawned".
    dpass,    \* Where the drain's pass is: "spawn" or "join".
    silent,   \* The drain's spawn step marked the box silent in this pass.
    final     \* History: an asker was answered a final refusal.

vars == <<row, sid, regs, reg, kept, slot, made, room, finished, started,
          ask, held, stub, dpass, silent, final>>

TypeOK ==
    /\ row \in {"none", "open", "releasing"}
    /\ sid \in 0..MaxMade
    /\ regs \subseteq 1..MaxMade
    /\ reg \in {"reserved", "saved"}
    /\ kept \in {"none", "noroom", "lost"}
    /\ slot \in {"none", "building", "closing", "running"}
    /\ ask \in [Askers -> {"idle", "poll", "ending", "done"}]
    /\ held \in [Askers -> 0..MaxMade]
    /\ stub \in {"requested", "refused", "spawned"}
    /\ dpass \in {"spawn", "join"}

Init ==
    /\ row = "none" /\ sid = None /\ regs = {} /\ reg = "reserved"
    /\ kept = "none" /\ slot = "none" /\ made = 0
    /\ room = FALSE /\ finished = FALSE /\ started = {}
    /\ ask = [a \in Askers |-> "idle"]
    /\ held = [a \in Askers |-> None]
    /\ stub = "requested" /\ dpass = "spawn" /\ silent = FALSE
    /\ final = FALSE

(***************************************************************************)
(* What an asker does with its answer. A handle records the stub spawned,  *)
(* over a refusal too (`remote_child.spawned`). A final refusal records it *)
(* refused unless it is already spawned, and the tool stops. A request to  *)
(* ask again sends the tool round again; for the drain it ends the spawn   *)
(* step, and without R3 it marks the box silent for the join step          *)
(* (`remote_drain.attempt_spawn`, where NotYetOpen is Unreachable).        *)
(***************************************************************************)
Done(a, next) ==
    /\ ask' = [ask EXCEPT ![a] = next]
    /\ held' = [held EXCEPT ![a] = None]

Heard(a, kind) ==
    /\ stub' = CASE kind = "handle" -> "spawned"
                 [] kind = "final" /\ stub = "requested" -> "refused"
                 [] OTHER -> stub
    /\ final' = (final \/ kind = "final")
    /\ IF a = "tool"
          THEN /\ Done(a, IF kind = "again" THEN "idle" ELSE "done")
               /\ UNCHANGED <<dpass, silent>>
          ELSE /\ Done(a, "idle")
               /\ dpass' = "join"
               /\ silent' = (kind = "again" /\ ~AnswerNotSilent)

(***************************************************************************)
(* Ending the child by name (`manager.release_delegate_child`): a row with *)
(* a slot goes releasing and its slot is stopped, and the slot's drain      *)
(* deletes it; a row with no slot is deleted with its registration in the  *)
(* same turn. It ends whatever registration the row names at that moment.  *)
(***************************************************************************)
EndByName ==
    IF row = "open"
       THEN IF slot = "none"
               THEN /\ row' = "none" /\ sid' = None /\ regs' = regs \ {sid}
                    /\ UNCHANGED slot
               ELSE /\ row' = "releasing"
                    /\ slot' = IF slot = "running" THEN "closing" ELSE slot
                    /\ UNCHANGED <<sid, regs>>
       ELSE UNCHANGED <<row, sid, regs, slot>>

\* A final refusal heard by an asker, with the end of the child's session.
Refused(a) ==
    /\ Heard(a, "final")
    /\ IF FinalReleases THEN EndByName ELSE UNCHANGED <<row, sid, regs, slot>>
    /\ UNCHANGED <<reg, kept, made, room, finished, started>>

\* A request to ask again, with nothing changed on the box.
Again(a) ==
    /\ Heard(a, "again")
    /\ UNCHANGED <<row, sid, regs, reg, kept, slot, made, room, finished, started>>

(***************************************************************************)
(* The registry's turn of an ask (`manager.delegate_now`).                  *)
(*                                                                         *)
(* No row: a reservation is made and built (`first_delegate`). A releasing *)
(* row is `DelegateReleased`, final. An open row with a slot that is       *)
(* building or running is admitted and polled, and one that is closing is  *)
(* answered stopping (`returning_delegate`). An open reserved row with no  *)
(* slot is the subject of the fix. Today admission refuses it              *)
(* `NotInitialized` and `reserved_refusal` reads the kept failure: no room *)
(* ends the row and asks again, anything else is final. With R1 the turn   *)
(* builds the same reservation again under its request key, and with the   *)
(* mutant it makes a new one beside it.                                    *)
(***************************************************************************)
Asking(a) ==
    \/ a = "tool" /\ ask[a] = "idle" /\ stub # "spawned"
    \/ a = "drain" /\ ask[a] = "idle" /\ dpass = "spawn" /\ stub = "requested"

Create(a) ==
    /\ made < MaxMade
    /\ row' = "open" /\ sid' = made + 1 /\ regs' = regs \cup {made + 1}
    /\ reg' = "reserved" /\ kept' = "none" /\ slot' = "building"
    /\ made' = made + 1
    /\ ask' = [ask EXCEPT ![a] = "poll"]
    /\ held' = [held EXCEPT ![a] = made + 1]
    /\ UNCHANGED <<room, finished, started, stub, dpass, silent, final>>

Poll(a, id) ==
    /\ ask' = [ask EXCEPT ![a] = "poll"]
    /\ held' = [held EXCEPT ![a] = id]

Admit(a) ==
    /\ Asking(a)
    /\ IF row = "none" THEN Create(a)
       ELSE IF row = "releasing" THEN Refused(a)
       ELSE IF slot \in {"building", "running"} THEN
            /\ Poll(a, sid)
            /\ UNCHANGED <<row, sid, regs, reg, kept, slot, made, room,
                           finished, started, stub, dpass, silent, final>>
       ELSE IF slot = "closing" THEN Again(a)
       ELSE IF reg = "saved" THEN
            \* A placed child's saved session is opened again.
            /\ slot' = "running" /\ Poll(a, sid)
            /\ UNCHANGED <<row, sid, regs, reg, kept, made, room, finished,
                           started, stub, dpass, silent, final>>
       ELSE IF RetryInPlace /\ ~RetryMakesNew THEN
            /\ slot' = "building" /\ kept' = "none" /\ Poll(a, sid)
            /\ UNCHANGED <<row, sid, regs, reg, made, room, finished, started,
                           stub, dpass, silent, final>>
       ELSE IF RetryInPlace THEN
            \* The old reservation is not deleted: it is a second registration.
            /\ made < MaxMade
            /\ sid' = made + 1 /\ regs' = regs \cup {made + 1}
            /\ reg' = "reserved" /\ kept' = "none" /\ slot' = "building"
            /\ made' = made + 1 /\ Poll(a, made + 1)
            /\ UNCHANGED <<row, room, finished, started, stub, dpass, silent, final>>
       ELSE IF kept = "noroom" THEN
            \* reserved_refusal: the row is ended and the sender asked again.
            /\ row' = "none" /\ sid' = None /\ regs' = regs \ {sid}
            /\ Heard(a, "again")
            /\ UNCHANGED <<reg, kept, slot, made, room, finished, started>>
       ELSE Refused(a)

(***************************************************************************)
(* The build ends. With a free scope the slot runs and the registration is *)
(* saved. Without one the registry keeps the failure and stops the slot in *)
(* one turn (`remember_failure(stop_slot(..))`). With LostFailure the      *)
(* catalogue may fail to keep it once, which leaves a bare reservation.   *)
(***************************************************************************)
BuildEnds ==
    /\ slot = "building"
    /\ IF room
          THEN /\ slot' = "running" /\ reg' = "saved"
               /\ UNCHANGED kept
          ELSE /\ slot' = "closing"
               /\ kept' \in IF LostFailure /\ kept # "lost"
                                THEN {"noroom", "lost"} ELSE {"noroom"}
               /\ UNCHANGED reg
    /\ UNCHANGED <<row, sid, regs, made, room, finished, started, ask, held,
                   stub, dpass, silent, final>>

(* The failed slot's custody drains. A releasing row is then deleted.       *)
Retire ==
    /\ slot = "closing"
    /\ slot' = "none"
    /\ IF row = "releasing"
          THEN row' = "none" /\ sid' = None /\ regs' = regs \ {sid}
          ELSE UNCHANGED <<row, sid, regs>>
    /\ UNCHANGED <<reg, kept, made, room, finished, started, ask, held, stub,
                   dpass, silent, final>>

(***************************************************************************)
(* One read of an admitted asker's poll (`delegate_host.resident`), in its *)
(* own step, so the other asker's steps fall between two reads.            *)
(*                                                                         *)
(* A registration that is gone reads `Missing`, which is a store failure,  *)
(* final. A running slot places the child: the claim lets one asker do the *)
(* work, and the Agency adopts the call site, so the second asker hears    *)
(* the same handle. A closing slot is stopping: ask again. A reservation   *)
(* with no slot whose failure is no room: today the asker answers ask      *)
(* again and then ends the row by name in a later step; with R1 it only    *)
(* answers ask again. A bare reservation is final today, ask again with R2.*)
(* A building slot is not read: the poll waits.                            *)
(***************************************************************************)
Gone(a) == held[a] \notin regs \/ held[a] # sid

Read(a) ==
    /\ ask[a] = "poll"
    /\ slot # "building" \/ Gone(a)
    /\ IF Gone(a) THEN Refused(a)
       ELSE IF slot = "running" THEN
            /\ started' = started \cup {sid}
            /\ Heard(a, "handle")
            /\ UNCHANGED <<row, sid, regs, reg, kept, slot, made, room, finished>>
       ELSE IF slot = "closing" \/ row = "releasing" THEN Again(a)
       ELSE IF kept = "noroom" /\ RetryInPlace THEN Again(a)
       ELSE IF kept = "noroom" THEN
            /\ ask' = [ask EXCEPT ![a] = "ending"]
            /\ UNCHANGED <<row, sid, regs, reg, kept, slot, made, room,
                           finished, started, held, stub, dpass, silent, final>>
       ELSE IF BareAsksAgain THEN Again(a)
       ELSE Refused(a)

(* The end by name that `child_resolver` makes after a no-room poll.        *)
End(a) ==
    /\ ask[a] = "ending"
    /\ EndByName
    /\ Heard(a, "again")
    /\ UNCHANGED <<reg, kept, made, room, finished, started>>

(***************************************************************************)
(* The drain's join step. Unless the spawn step marked the box silent, it  *)
(* joins the parent's running children, and a finished child's join frees *)
(* its scope. A pass with no requested stub has no spawn step.             *)
(***************************************************************************)
SkipSpawn ==
    /\ dpass = "spawn" /\ ask["drain"] = "idle" /\ stub # "requested"
    /\ dpass' = "join" /\ silent' = FALSE
    /\ UNCHANGED <<row, sid, regs, reg, kept, slot, made, room, finished,
                   started, ask, held, stub, final>>

Join ==
    /\ dpass = "join"
    /\ room' = (room \/ (finished /\ ~silent))
    /\ dpass' = "spawn" /\ silent' = FALSE
    /\ UNCHANGED <<row, sid, regs, reg, kept, slot, made, finished, started,
                   ask, held, stub, final>>

(* Another child of the parent finishes. Its scope is held until its join. *)
Finish ==
    /\ ~finished
    /\ finished' = TRUE
    /\ UNCHANGED <<row, sid, regs, reg, kept, slot, made, room, started, ask,
                   held, stub, dpass, silent, final>>

Next ==
    \/ \E a \in Askers : Admit(a) \/ Read(a) \/ End(a)
    \/ BuildEnds \/ Retire \/ SkipSpawn \/ Join \/ Finish

(***************************************************************************)
(* Fairness. A poll reads every 200 ms, so a status that recurs is read:   *)
(* the read is strongly fair, since the other asker's rebuilds make the    *)
(* slot building again between two of its reads. The poll's 20 s bound is  *)
(* not modelled. Every other step is weakly fair.                          *)
(***************************************************************************)
Spec ==
    /\ Init /\ [][Next]_vars
    /\ WF_vars(BuildEnds) /\ WF_vars(Retire) /\ WF_vars(Finish)
    /\ WF_vars(SkipSpawn) /\ WF_vars(Join)
    /\ \A a \in Askers : WF_vars(Admit(a)) /\ SF_vars(Read(a)) /\ WF_vars(End(a))

(***************************************************************************)
(* Properties.                                                             *)
(*                                                                         *)
(* NoRoomNeverFinal (P1): every build in the model fails only for want of  *)
(* room, so no asker is ever answered a final refusal.                     *)
(*                                                                         *)
(* PlacedOnceRoomFrees (P2): the child is placed and the parent's stub     *)
(* learns its handle, while both askers keep asking and another child      *)
(* finishes.                                                               *)
(*                                                                         *)
(* OneSessionPerChild (P3): at most one registration exists for the child, *)
(* and at most one child is started for it.                                *)
(*                                                                         *)
(* NothingHeldUnplaced (P4): once the parent has stopped asking with the   *)
(* child unplaced and no ask is in flight, no row, registration or slot    *)
(* is left for it.                                                         *)
(***************************************************************************)
NoRoomNeverFinal == ~final

PlacedOnceRoomFrees == <>(stub = "spawned")

OneSessionPerChild == Cardinality(regs) <= 1 /\ Cardinality(started) <= 1

Quiet == \A a \in Askers : ask[a] \in {"idle", "done"}

NothingHeldUnplaced ==
    (stub = "refused" /\ Quiet /\ slot = "none")
        => (row = "none" /\ regs = {})

=============================================================================
