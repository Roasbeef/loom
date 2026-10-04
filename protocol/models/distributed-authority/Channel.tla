----------------------------- MODULE Channel -----------------------------
EXTENDS Naturals, FiniteSets, Sequences, TLC

\* Scaled byte units and finite equality classes describe custody rather than
\* TLS authentication, physical memory, durable execution or native retirement.
CONSTANTS Quota, Mutation, TerminalKind
Directions == 1..2
Items == 1..3
Source == <<1, 2, 3>>
Size(i) == IF i = 2 THEN 2 ELSE 1
Members(s) == {s[i] : i \in 1..Len(s)}
Bytes(s) == Len(s) + IF 2 \in Members(s) THEN 1 ELSE 0
Prefix(s) == s = SubSeq(Source, 1, Len(s))
ASSUME /\ Quota \in {3, 4}
       /\ TerminalKind \in {"Outcome", "HookResult"}
       /\ Mutation \in {"none", "network_ack", "timeout", "restart",
                         "quota", "dropped_success", "control"}

(* --algorithm ChannelCredits
variables
    admitted = [d \in Directions |-> <<>>],
    usedBytes = [d \in Directions |-> 0],
    transport = [d \in Directions |-> <<>>],
    consumer = [d \in Directions |-> <<>>],
    consumed = [d \in Directions |-> <<>>],
    pending = [d \in Directions |-> {}],
    ack = [d \in Directions |-> 0],
    acked = [d \in Directions |-> {}],
    open = [d \in Directions |-> TRUE],
    ownerAlive = [d \in Directions |-> TRUE],
    recipientAlive = [d \in Directions |-> TRUE],
    timedOut = [d \in Directions |-> FALSE],
    invalidated = [d \in Directions |-> FALSE],
    reminted = [d \in Directions |-> FALSE],
    lateConsumed = [d \in Directions |-> {}],
    lateAck = FALSE,
    failed = FALSE,
    lossHistory = FALSE,
    quotaFailure = FALSE,
    controlQueued = FALSE,
    cancelConsumed = FALSE,
    cancelPressure = FALSE,
    terminalSeen = "None",
    success = FALSE;
define
    \* This is the actual cancellation action guard. The invariant states its
    \* premise independently, so gating this guard on a data credit is visible.
    ControlReady == controlQueued /\ recipientAlive[1]
                    /\ (Mutation # "control" \/ pending[1] = {})
end define;
begin
Step:
  while TRUE do
    await ~success;
    either
      with d \in Directions do
        await open[d] /\ ownerAlive[d] /\ ~failed
              /\ pending[d] = {} /\ Len(admitted[d]) < 3;
        with i = Len(admitted[d]) + 1 do
          \* History and the mutable admission counter are separate facts.
          if usedBytes[d] + Size(i) <= Quota \/ Mutation = "quota" then
            admitted[d] := Append(admitted[d], i);
            usedBytes[d] := usedBytes[d] + Size(i);
            transport[d] := Append(transport[d], i);
            pending[d] := {i};
          else
            failed := TRUE;
            lossHistory := TRUE;
            quotaFailure := TRUE;
          end if;
        end with;
      end with;
    or
      with d \in Directions do
        await transport[d] # <<>> /\ recipientAlive[d];
        consumer[d] := Append(consumer[d], Head(transport[d]));
        transport[d] := Tail(transport[d]);
        \* Network drainage does not release final-consumer custody.
        if Mutation = "network_ack" then pending[d] := {}; end if;
      end with;
    or
      with d \in Directions do
        await consumer[d] # <<>> /\ recipientAlive[d] /\ ack[d] = 0;
        \* Remember the exact original item consumed after its observer timed out.
        if timedOut[d] /\ Head(consumer[d]) \in pending[d] then
          lateConsumed[d] := lateConsumed[d] \cup {Head(consumer[d])};
        end if;
        ack[d] := Head(consumer[d]);
        consumed[d] := Append(consumed[d], Head(consumer[d]));
        if d = 2 /\ Head(consumer[d]) = 3 then
          terminalSeen := TerminalKind;
          \* The final host accepts success only while consuming the terminal.
          \* This cannot defer its loss check beyond the consumption boundary.
          if ~failed \/ Mutation = "dropped_success" then success := TRUE; end if;
        end if;
        consumer[d] := Tail(consumer[d]);
      end with;
    or
      with d \in Directions do
        await ack[d] # 0 /\ ownerAlive[d];
        \* A delayed ACK for earlier consumption cannot establish this witness.
        if ack[d] \in lateConsumed[d] /\ ack[d] \in pending[d] /\ ~open[d] then
          lateAck := TRUE;
        end if;
        pending[d] := pending[d] \ {ack[d]};
        acked[d] := acked[d] \cup {ack[d]};
        ack[d] := 0;
      end with;
    or
      with d \in Directions do
        await open[d] /\ pending[d] # {} /\ ~timedOut[d];
        timedOut[d] := TRUE;
        invalidated[d] := TRUE;
        \* The original final queue survives an observer timeout.
        if Mutation = "timeout" then
          open[d] := TRUE;
          pending[d] := {};
          reminted[d] := TRUE;
        else
          open[d] := FALSE;
        end if;
      end with;
    or
      with d \in Directions do
        await ownerAlive[d] /\ pending[d] # {} /\ ~invalidated[d];
        invalidated[d] := TRUE;
        \* Replacement in the same sink is deliberately a mutation only.
        if Mutation = "restart" then
          ownerAlive[d] := TRUE;
          open[d] := TRUE;
          pending[d] := {};
          reminted[d] := TRUE;
        else
          ownerAlive[d] := FALSE;
          open[d] := FALSE;
        end if;
      end with;
    or
      with d \in Directions do
        await transport[d] # <<>> /\ open[d];
        transport[d] := <<>>;
        open[d] := FALSE;
        failed := TRUE;
        lossHistory := TRUE;
      end with;
    or
      await ~controlQueued /\ ~cancelConsumed /\ recipientAlive[1];
      controlQueued := TRUE;
    or
      await ControlReady;
      controlQueued := FALSE;
      cancelConsumed := TRUE;
      if pending[1] # {} /\ pending[2] # {} then cancelPressure := TRUE; end if;
    end either;
  end while;
end algorithm; *)

\* BEGIN TRANSLATION
VARIABLES admitted, usedBytes, transport, consumer, consumed, pending, ack,
          acked, open, ownerAlive, recipientAlive, timedOut, invalidated,
          reminted, lateConsumed, lateAck, failed, lossHistory, quotaFailure,
          controlQueued, cancelConsumed, cancelPressure, terminalSeen,
          success

(* define statement *)
ControlReady == controlQueued /\ recipientAlive[1]
                /\ (Mutation # "control" \/ pending[1] = {})


vars == << admitted, usedBytes, transport, consumer, consumed, pending, ack,
           acked, open, ownerAlive, recipientAlive, timedOut, invalidated,
           reminted, lateConsumed, lateAck, failed, lossHistory, quotaFailure,
           controlQueued, cancelConsumed, cancelPressure, terminalSeen,
           success >>

Init == (* Global variables *)
        /\ admitted = [d \in Directions |-> <<>>]
        /\ usedBytes = [d \in Directions |-> 0]
        /\ transport = [d \in Directions |-> <<>>]
        /\ consumer = [d \in Directions |-> <<>>]
        /\ consumed = [d \in Directions |-> <<>>]
        /\ pending = [d \in Directions |-> {}]
        /\ ack = [d \in Directions |-> 0]
        /\ acked = [d \in Directions |-> {}]
        /\ open = [d \in Directions |-> TRUE]
        /\ ownerAlive = [d \in Directions |-> TRUE]
        /\ recipientAlive = [d \in Directions |-> TRUE]
        /\ timedOut = [d \in Directions |-> FALSE]
        /\ invalidated = [d \in Directions |-> FALSE]
        /\ reminted = [d \in Directions |-> FALSE]
        /\ lateConsumed = [d \in Directions |-> {}]
        /\ lateAck = FALSE
        /\ failed = FALSE
        /\ lossHistory = FALSE
        /\ quotaFailure = FALSE
        /\ controlQueued = FALSE
        /\ cancelConsumed = FALSE
        /\ cancelPressure = FALSE
        /\ terminalSeen = "None"
        /\ success = FALSE

Next == /\ ~success
        /\ \/ /\ \E d \in Directions:
                   /\ open[d] /\ ownerAlive[d] /\ ~failed
                      /\ pending[d] = {} /\ Len(admitted[d]) < 3
                   /\ LET i == Len(admitted[d]) + 1 IN
                        IF usedBytes[d] + Size(i) <= Quota \/ Mutation = "quota"
                           THEN /\ admitted' = [admitted EXCEPT ![d] = Append(admitted[d], i)]
                                /\ usedBytes' = [usedBytes EXCEPT ![d] = usedBytes[d] + Size(i)]
                                /\ transport' = [transport EXCEPT ![d] = Append(transport[d], i)]
                                /\ pending' = [pending EXCEPT ![d] = {i}]
                                /\ UNCHANGED << failed, lossHistory,
                                                quotaFailure >>
                           ELSE /\ failed' = TRUE
                                /\ lossHistory' = TRUE
                                /\ quotaFailure' = TRUE
                                /\ UNCHANGED << admitted, usedBytes, transport,
                                                pending >>
              /\ UNCHANGED <<consumer, consumed, ack, acked, open, ownerAlive, timedOut, invalidated, reminted, lateConsumed, lateAck, controlQueued, cancelConsumed, cancelPressure, terminalSeen, success>>
           \/ /\ \E d \in Directions:
                   /\ transport[d] # <<>> /\ recipientAlive[d]
                   /\ consumer' = [consumer EXCEPT ![d] = Append(consumer[d], Head(transport[d]))]
                   /\ transport' = [transport EXCEPT ![d] = Tail(transport[d])]
                   /\ IF Mutation = "network_ack"
                         THEN /\ pending' = [pending EXCEPT ![d] = {}]
                         ELSE /\ TRUE
                              /\ UNCHANGED pending
              /\ UNCHANGED <<admitted, usedBytes, consumed, ack, acked, open, ownerAlive, timedOut, invalidated, reminted, lateConsumed, lateAck, failed, lossHistory, quotaFailure, controlQueued, cancelConsumed, cancelPressure, terminalSeen, success>>
           \/ /\ \E d \in Directions:
                   /\ consumer[d] # <<>> /\ recipientAlive[d] /\ ack[d] = 0
                   /\ IF timedOut[d] /\ Head(consumer[d]) \in pending[d]
                         THEN /\ lateConsumed' = [lateConsumed EXCEPT ![d] = lateConsumed[d] \cup {Head(consumer[d])}]
                         ELSE /\ TRUE
                              /\ UNCHANGED lateConsumed
                   /\ ack' = [ack EXCEPT ![d] = Head(consumer[d])]
                   /\ consumed' = [consumed EXCEPT ![d] = Append(consumed[d], Head(consumer[d]))]
                   /\ IF d = 2 /\ Head(consumer[d]) = 3
                         THEN /\ terminalSeen' = TerminalKind
                              /\ IF ~failed \/ Mutation = "dropped_success"
                                    THEN /\ success' = TRUE
                                    ELSE /\ TRUE
                                         /\ UNCHANGED success
                         ELSE /\ TRUE
                              /\ UNCHANGED << terminalSeen, success >>
                   /\ consumer' = [consumer EXCEPT ![d] = Tail(consumer[d])]
              /\ UNCHANGED <<admitted, usedBytes, transport, pending, acked, open, ownerAlive, timedOut, invalidated, reminted, lateAck, failed, lossHistory, quotaFailure, controlQueued, cancelConsumed, cancelPressure>>
           \/ /\ \E d \in Directions:
                   /\ ack[d] # 0 /\ ownerAlive[d]
                   /\ IF ack[d] \in lateConsumed[d] /\ ack[d] \in pending[d] /\ ~open[d]
                         THEN /\ lateAck' = TRUE
                         ELSE /\ TRUE
                              /\ UNCHANGED lateAck
                   /\ pending' = [pending EXCEPT ![d] = pending[d] \ {ack[d]}]
                   /\ acked' = [acked EXCEPT ![d] = acked[d] \cup {ack[d]}]
                   /\ ack' = [ack EXCEPT ![d] = 0]
              /\ UNCHANGED <<admitted, usedBytes, transport, consumer, consumed, open, ownerAlive, timedOut, invalidated, reminted, lateConsumed, failed, lossHistory, quotaFailure, controlQueued, cancelConsumed, cancelPressure, terminalSeen, success>>
           \/ /\ \E d \in Directions:
                   /\ open[d] /\ pending[d] # {} /\ ~timedOut[d]
                   /\ timedOut' = [timedOut EXCEPT ![d] = TRUE]
                   /\ invalidated' = [invalidated EXCEPT ![d] = TRUE]
                   /\ IF Mutation = "timeout"
                         THEN /\ open' = [open EXCEPT ![d] = TRUE]
                              /\ pending' = [pending EXCEPT ![d] = {}]
                              /\ reminted' = [reminted EXCEPT ![d] = TRUE]
                         ELSE /\ open' = [open EXCEPT ![d] = FALSE]
                              /\ UNCHANGED << pending, reminted >>
              /\ UNCHANGED <<admitted, usedBytes, transport, consumer, consumed, ack, acked, ownerAlive, lateConsumed, lateAck, failed, lossHistory, quotaFailure, controlQueued, cancelConsumed, cancelPressure, terminalSeen, success>>
           \/ /\ \E d \in Directions:
                   /\ ownerAlive[d] /\ pending[d] # {} /\ ~invalidated[d]
                   /\ invalidated' = [invalidated EXCEPT ![d] = TRUE]
                   /\ IF Mutation = "restart"
                         THEN /\ ownerAlive' = [ownerAlive EXCEPT ![d] = TRUE]
                              /\ open' = [open EXCEPT ![d] = TRUE]
                              /\ pending' = [pending EXCEPT ![d] = {}]
                              /\ reminted' = [reminted EXCEPT ![d] = TRUE]
                         ELSE /\ ownerAlive' = [ownerAlive EXCEPT ![d] = FALSE]
                              /\ open' = [open EXCEPT ![d] = FALSE]
                              /\ UNCHANGED << pending, reminted >>
              /\ UNCHANGED <<admitted, usedBytes, transport, consumer, consumed, ack, acked, timedOut, lateConsumed, lateAck, failed, lossHistory, quotaFailure, controlQueued, cancelConsumed, cancelPressure, terminalSeen, success>>
           \/ /\ \E d \in Directions:
                   /\ transport[d] # <<>> /\ open[d]
                   /\ transport' = [transport EXCEPT ![d] = <<>>]
                   /\ open' = [open EXCEPT ![d] = FALSE]
                   /\ failed' = TRUE
                   /\ lossHistory' = TRUE
              /\ UNCHANGED <<admitted, usedBytes, consumer, consumed, pending, ack, acked, ownerAlive, timedOut, invalidated, reminted, lateConsumed, lateAck, quotaFailure, controlQueued, cancelConsumed, cancelPressure, terminalSeen, success>>
           \/ /\ ~controlQueued /\ ~cancelConsumed /\ recipientAlive[1]
              /\ controlQueued' = TRUE
              /\ UNCHANGED <<admitted, usedBytes, transport, consumer, consumed, pending, ack, acked, open, ownerAlive, timedOut, invalidated, reminted, lateConsumed, lateAck, failed, lossHistory, quotaFailure, cancelConsumed, cancelPressure, terminalSeen, success>>
           \/ /\ ControlReady
              /\ controlQueued' = FALSE
              /\ cancelConsumed' = TRUE
              /\ IF pending[1] # {} /\ pending[2] # {}
                    THEN /\ cancelPressure' = TRUE
                    ELSE /\ TRUE
                         /\ UNCHANGED cancelPressure
              /\ UNCHANGED <<admitted, usedBytes, transport, consumer, consumed, pending, ack, acked, open, ownerAlive, timedOut, invalidated, reminted, lateConsumed, lateAck, failed, lossHistory, quotaFailure, terminalSeen, success>>
        /\ UNCHANGED recipientAlive

Spec == Init /\ [][Next]_vars

\* END TRANSLATION

TypeOK == /\ admitted \in [Directions -> Seq(Items)]
          /\ consumed \in [Directions -> Seq(Items)]
          /\ transport \in [Directions -> Seq(Items)]
          /\ consumer \in [Directions -> Seq(Items)]
          /\ \A d \in Directions : Len(admitted[d]) <= 3
                                     /\ Len(consumed[d]) <= 3
                                     /\ Len(transport[d]) <= 3
                                     /\ Len(consumer[d]) <= 3
          /\ pending \in [Directions -> SUBSET Items]
          /\ ack \in [Directions -> 0..3]
          /\ acked \in [Directions -> SUBSET Items]
          /\ lateConsumed \in [Directions -> SUBSET Items]
          /\ usedBytes \in [Directions -> 0..4]
          /\ open \in [Directions -> BOOLEAN]
          /\ ownerAlive \in [Directions -> BOOLEAN]
          /\ recipientAlive \in [Directions -> BOOLEAN]
          /\ timedOut \in [Directions -> BOOLEAN]
          /\ invalidated \in [Directions -> BOOLEAN]
          /\ reminted \in [Directions -> BOOLEAN]
          /\ lateAck \in BOOLEAN /\ failed \in BOOLEAN /\ lossHistory \in BOOLEAN
          /\ quotaFailure \in BOOLEAN /\ controlQueued \in BOOLEAN
          /\ cancelConsumed \in BOOLEAN /\ cancelPressure \in BOOLEAN
          /\ terminalSeen \in {"None", "Outcome", "HookResult"}
          /\ success \in BOOLEAN
PendingBound == \A d \in Directions : Cardinality(pending[d]) <= 1
ConsumerBound == \A d \in Directions : Len(consumer[d]) <= 1
QueueHasCredit == \A d \in Directions :
                  Members(transport[d]) \cup Members(consumer[d]) \subseteq pending[d]
AckHasConsumption == \A d \in Directions :
                     /\ acked[d] \subseteq Members(consumed[d])
                     /\ (ack[d] # 0 => ack[d] \in Members(consumed[d]))
OrderedConsumption == \A d \in Directions : Prefix(consumed[d]) /\ Prefix(admitted[d])
LifetimeBytesBound == \A d \in Directions : Bytes(admitted[d]) <= Quota
NoSuccessAfterLoss == success => consumed[2] = Source /\ terminalSeen = TerminalKind /\ ~lossHistory
NoRemintedCredit == \A d \in Directions : invalidated[d] => ~open[d]
ControlIndependent == controlQueued /\ recipientAlive[1] => ControlReady
NoCompleteStream == ~success
NoBidirectionalPending == ~(\A d \in Directions : consumer[d] # <<>> \/ ack[d] # 0)
NoLateConsumptionAck == ~lateAck
NoQuotaFailure == ~quotaFailure
NoCancelUnderPressure == ~cancelPressure
=============================================================================
