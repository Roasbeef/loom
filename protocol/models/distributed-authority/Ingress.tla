----------------------------- MODULE Ingress -----------------------------
EXTENDS Naturals, FiniteSets, TLC

\* A listener credit outlives its socket worker. Pending includes a queued
\* service message and a consumed message whose final reply is still delayed.
\* Killing the socket changes neither fact. A crashed listener is not replaced
\* while its old service message can survive. This models custody, not bytes,
\* fairness, TLS framing or SQLite durability.
CONSTANT Mutation, Capacity
Lanes == 1..Capacity
Requests == 1..3
ASSUME /\ Capacity \in 1..2
       /\ Mutation \in {"none", "timeout_recycles", "restart_recycles"}

(* --algorithm IngressCredits
variables
    lane = [i \in Lanes |-> "Idle"],
    socket = [i \in Lanes |-> "Ended"],
    pending = [i \in Lanes |-> {}],
    queued = {},
    consumed = {},
    used = {},
    service = "Alive",
    timedOut = FALSE,
    recovered = FALSE,
    reused = FALSE,
    crashed = FALSE;
begin
Step:
  while TRUE do
    either
      \* Admission is possible only when the preceding exchange's entire
      \* custody has ended. Each request is sent at most once in this model.
      await service = "Alive";
      with i \in Lanes, r \in Requests \ used do
        await lane[i] = "Idle";
        if timedOut /\ used # {} then reused := TRUE; end if;
        lane[i] := "Busy";
        socket[i] := "Live";
        pending[i] := pending[i] \cup {r};
        queued := queued \cup {r};
        used := used \cup {r};
      end with;
    or
      \* The peer or deadline ends the socket while the service may be stalled.
      with i \in Lanes do
        await lane[i] = "Busy" /\ socket[i] = "Live";
        socket[i] := "Ended";
        timedOut := TRUE;
        if Mutation = "timeout_recycles" then lane[i] := "Idle"; end if;
      end with;
    or
      \* Actual service consumption releases payload retention, but the credit
      \* owner still waits for the reply proving that this happened.
      await service = "Alive";
      with r \in queued do
        queued := queued \ {r};
        consumed := consumed \cup {r};
      end with;
    or
      with i \in Lanes, r \in pending[i] \cap consumed do
        await lane[i] # "Dead";
        pending[i] := pending[i] \ {r};
        if timedOut then recovered := TRUE; end if;
      end with;
    or
      \* Both independent lifetimes must end before one lane is reused.
      with i \in Lanes do
        await lane[i] = "Busy" /\ socket[i] = "Ended" /\ pending[i] = {};
        lane[i] := "Idle";
      end with;
    or
      \* Temporary listener children lose capacity on crash. A replacement
      \* cannot infer that the original queued message died with its sender.
      with i \in Lanes do
        await lane[i] = "Busy";
        if Mutation = "restart_recycles" then
          lane[i] := "Idle";
        else
          lane[i] := "Dead";
        end if;
        socket[i] := "Ended";
        crashed := TRUE;
      end with;
    or
      \* Confirmed service death destroys its mailbox. No new request can
      \* enter this incarnation; deployment recovery is outside this model.
      await service = "Alive";
      service := "Dead";
      queued := {};
    end either;
  end while;
end algorithm; *)

\* BEGIN TRANSLATION
VARIABLES lane, socket, pending, queued, consumed, used, service, timedOut,
          recovered, reused, crashed

vars == << lane, socket, pending, queued, consumed, used, service, timedOut,
           recovered, reused, crashed >>

Init == (* Global variables *)
        /\ lane = [i \in Lanes |-> "Idle"]
        /\ socket = [i \in Lanes |-> "Ended"]
        /\ pending = [i \in Lanes |-> {}]
        /\ queued = {}
        /\ consumed = {}
        /\ used = {}
        /\ service = "Alive"
        /\ timedOut = FALSE
        /\ recovered = FALSE
        /\ reused = FALSE
        /\ crashed = FALSE

Next == \/ /\ service = "Alive"
           /\ \E i \in Lanes:
                \E r \in Requests \ used:
                  /\ lane[i] = "Idle"
                  /\ IF timedOut /\ used # {}
                        THEN /\ reused' = TRUE
                        ELSE /\ TRUE
                             /\ UNCHANGED reused
                  /\ lane' = [lane EXCEPT ![i] = "Busy"]
                  /\ socket' = [socket EXCEPT ![i] = "Live"]
                  /\ pending' = [pending EXCEPT ![i] = pending[i] \cup {r}]
                  /\ queued' = (queued \cup {r})
                  /\ used' = (used \cup {r})
           /\ UNCHANGED <<consumed, service, timedOut, recovered, crashed>>
        \/ /\ \E i \in Lanes:
                /\ lane[i] = "Busy" /\ socket[i] = "Live"
                /\ socket' = [socket EXCEPT ![i] = "Ended"]
                /\ timedOut' = TRUE
                /\ IF Mutation = "timeout_recycles"
                      THEN /\ lane' = [lane EXCEPT ![i] = "Idle"]
                      ELSE /\ TRUE
                           /\ lane' = lane
           /\ UNCHANGED <<pending, queued, consumed, used, service, recovered, reused, crashed>>
        \/ /\ service = "Alive"
           /\ \E r \in queued:
                /\ queued' = queued \ {r}
                /\ consumed' = (consumed \cup {r})
           /\ UNCHANGED <<lane, socket, pending, used, service, timedOut, recovered, reused, crashed>>
        \/ /\ \E i \in Lanes:
                \E r \in pending[i] \cap consumed:
                  /\ lane[i] # "Dead"
                  /\ pending' = [pending EXCEPT ![i] = pending[i] \ {r}]
                  /\ IF timedOut
                        THEN /\ recovered' = TRUE
                        ELSE /\ TRUE
                             /\ UNCHANGED recovered
           /\ UNCHANGED <<lane, socket, queued, consumed, used, service, timedOut, reused, crashed>>
        \/ /\ \E i \in Lanes:
                /\ lane[i] = "Busy" /\ socket[i] = "Ended" /\ pending[i] = {}
                /\ lane' = [lane EXCEPT ![i] = "Idle"]
           /\ UNCHANGED <<socket, pending, queued, consumed, used, service, timedOut, recovered, reused, crashed>>
        \/ /\ \E i \in Lanes:
                /\ lane[i] = "Busy"
                /\ IF Mutation = "restart_recycles"
                      THEN /\ lane' = [lane EXCEPT ![i] = "Idle"]
                      ELSE /\ lane' = [lane EXCEPT ![i] = "Dead"]
                /\ socket' = [socket EXCEPT ![i] = "Ended"]
                /\ crashed' = TRUE
           /\ UNCHANGED <<pending, queued, consumed, used, service, timedOut, recovered, reused>>
        \/ /\ service = "Alive"
           /\ service' = "Dead"
           /\ queued' = {}
           /\ UNCHANGED <<lane, socket, pending, consumed, used, timedOut, recovered, reused, crashed>>

Spec == Init /\ [][Next]_vars

\* END TRANSLATION

TypeOK == /\ lane \in [Lanes -> {"Idle", "Busy", "Dead"}]
          /\ socket \in [Lanes -> {"Live", "Ended"}]
          /\ pending \in [Lanes -> SUBSET Requests]
          /\ queued \subseteq used
          /\ consumed \subseteq used
          /\ used \subseteq Requests
          /\ service \in {"Alive", "Dead"}
          /\ timedOut \in BOOLEAN /\ recovered \in BOOLEAN
          /\ crashed \in BOOLEAN /\ reused \in BOOLEAN
PendingBound == \A i \in Lanes : Cardinality(pending[i]) <= 1
QueueBound == Cardinality(queued) <= Capacity
QueueHasCustody == \A r \in queued : \E i \in Lanes : r \in pending[i]
NoReuseWithPending == \A i \in Lanes : lane[i] = "Idle" => pending[i] = {}
NoTimedOutRecovery == ~recovered
NoReuseAfterTimeout == ~reused
NoCrashWithPending == ~(crashed /\ \E i \in Lanes : lane[i] = "Dead" /\ pending[i] # {})
=============================================================================
