----------------------------- MODULE Metadata -----------------------------
EXTENDS Naturals, FiniteSets, TLC

\* A store-independent refinement of Ownership's serialized metadata step.
\* Submission is not settlement, and settlement is not a caller reply. Every
\* accepted ID reserves retained receipt space before any command can settle.
\* A deadline changes only caller knowledge; the original command stays live.
\* No routing observation or historical receipt constructs a writer grant.

CONSTANT Mutation, Capacity
Ids == 1..2
Slots == 1..3
Initial == [incarnation |-> 1, revision |-> 1, epoch |-> 1, owner |-> "A"]
EmptyReceipt == [digest |-> 0, result |-> "Absent", value |-> Initial]
EmptyRequest == [id |-> 1, digest |-> 1, expected |-> Initial,
                 purpose |-> "Primary"]

ASSUME /\ Capacity \in 1..2
       /\ Mutation \in {"none", "timeout_no_commit", "retry_new_id",
                         "minority_ack", "aba_reset", "forget_receipt"}

(* --algorithm ConditionalMetadata
variables
    authority = Initial,
    highWater = 1,
    recreated = FALSE,
    reserved = {},
    receipts = [id \in Ids |-> EmptyReceipt],
    receiptFacts = {},
    compacted = FALSE,
    requests = [slot \in Slots |-> EmptyRequest],
    submitted = {},
    settled = {},
    replies = [slot \in Slots |-> "None"],
    primaryId = 1,
    view = "Idle",
    path = "Majority",
    timeoutObserved = FALSE,
    missingObserved = FALSE,
    lostObserved = FALSE,
    reconciled = FALSE,
    reconciledAfterLoss = FALSE,
    reconciledAfterCompaction = FALSE,
    lateReply = FALSE,
    conflictObserved = FALSE,
    capacityRefused = FALSE,
    acknowledgements = {},
    minoritySubmitted = FALSE,
    minorityTimedOut = FALSE,
    staleRejectedAfterRecreate = FALSE,
    primaryCommits = 0;

begin
Step:
    while TRUE do
      either
        \* The stable identity, exact predicate and receipt reservation precede
        \* transmission. The caller may submit while isolated from a quorum.
        await 1 \notin submitted;
        reserved := reserved \cup {1};
        submitted := submitted \cup {1};
        minoritySubmitted := path = "Minority";
        view := "Pending";

      or
        \* Retry the unresolved operation, including its original predicate.
        \* The mutant instead refreshes the predicate under a new identity;
        \* it can commit the same logical transition a second time.
        await timeoutObserved /\ view = "Unknown" /\ 2 \notin submitted;
        if Mutation = "retry_new_id" /\ Capacity = 2 then
            primaryId := 2;
            reserved := reserved \cup {2};
            requests[2] := [id |-> 2, digest |-> 1, expected |-> authority,
                            purpose |-> "Primary"];
        else
            requests[2] := requests[1];
        end if;
        submitted := submitted \cup {2};

      or
        \* A delayed contender carries the initial observation, or a reused
        \* primary ID carries a conflicting digest. Capacity never evicts an
        \* unknown operation to admit this contender.
        await 1 \in submitted /\ 3 \notin submitted;
        with kind \in {"Stale", "Conflict"} do
            if kind = "Conflict" then
                requests[3] := [id |-> 1, digest |-> 2, expected |-> Initial,
                                purpose |-> "Other"];
                submitted := submitted \cup {3};
            elsif 2 \in reserved \/ Cardinality(reserved) < Capacity then
                reserved := reserved \cup {2};
                requests[3] := [id |-> 2, digest |-> 1, expected |-> Initial,
                                purpose |-> "Other"];
                submitted := submitted \cup {3};
            else
                capacityRefused := TRUE;
            end if;
        end with;

      or
        \* Quorum settlement resolves each submitted envelope. Exact-ID lookup
        \* comes before conditional mutation. The final rejection is retained
        \* too; a digest conflict cannot rewrite the original receipt.
        await path = "Majority";
        with slot \in submitted \ settled do
            if requests[slot].digest # 1 then
                replies[slot] := "Conflict";
                conflictObserved := TRUE;
            elsif receipts[requests[slot].id].result # "Absent" then
                if receipts[requests[slot].id].digest = requests[slot].digest then
                    replies[slot] := receipts[requests[slot].id].result;
                else
                    replies[slot] := "Conflict";
                    conflictObserved := TRUE;
                end if;
            elsif authority = requests[slot].expected then
                authority := [authority EXCEPT !.revision = @ + 1,
                               !.epoch = @ + 1, !.owner = "B"];
                highWater := authority.epoch;
                receipts[requests[slot].id] := [digest |-> requests[slot].digest,
                    result |-> "Applied", value |-> authority];
                receiptFacts := receiptFacts \cup {<<requests[slot].id, receipts[requests[slot].id]>>};
                replies[slot] := "Applied";
                if requests[slot].purpose = "Primary" then
                    primaryCommits := primaryCommits + 1;
                end if;
            else
                receipts[requests[slot].id] := [digest |-> requests[slot].digest,
                    result |-> "Rejected", value |-> authority];
                receiptFacts := receiptFacts \cup {<<requests[slot].id, receipts[requests[slot].id]>>};
                replies[slot] := "Rejected";
                if slot = 3 /\ requests[slot].id = 2 /\ recreated then
                    staleRejectedAfterRecreate := TRUE;
                end if;
            end if;
            settled := settled \cup {slot};
        end with;

      or
        \* A deadline can precede settlement or follow a commit whose reply is
        \* delayed. It never retracts an envelope or proves receipt absence.
        await 1 \in submitted /\ view \in {"Pending", "Unknown"};
        timeoutObserved := TRUE;
        if path = "Minority" /\ 1 \notin settled then
            minorityTimedOut := TRUE;
        end if;
        if Mutation = "timeout_no_commit" then
            view := "NoCommit";
        else
            view := "Unknown";
        end if;

      or
        \* A quorum receipt lookup before settlement still leaves uncertainty.
        \* Reconciliation preserves the operation identity and stored outcome.
        await 1 \in submitted /\ path = "Majority";
        if receipts[primaryId].result = "Absent" then
            missingObserved := TRUE;
            view := "Unknown";
        else
            view := receipts[primaryId].result;
            reconciled := TRUE;
            if lostObserved then reconciledAfterLoss := TRUE; end if;
            if compacted then reconciledAfterCompaction := TRUE; end if;
        end if;

      or
        \* Settlement survives loss of the corresponding application reply.
        with slot \in settled do
            await replies[slot] \in {"Applied", "Rejected", "Conflict"};
            if requests[slot].purpose = "Primary" /\ replies[slot] = "Applied" then
                lostObserved := TRUE;
            end if;
            replies[slot] := "Lost";
        end with;

      or
        \* Delivery reports a historical result, not a current owner grant.
        \* A previously committed receipt remains valid after partition. Only
        \* an unsettled command needs a quorum before it can be acknowledged.
        await path # "Offline";
        with slot \in settled do
            await replies[slot] \in {"Applied", "Rejected"}
                  /\ requests[slot].purpose = "Primary";
            acknowledgements := acknowledgements \cup {slot};
            view := replies[slot];
            lateReply := timeoutObserved;
            replies[slot] := "Delivered";
        end with;

      or
        \* The negative control fabricates a successful minority reply before
        \* any quorum settlement. A transport success cannot stand in for the
        \* missing durable receipt.
        await Mutation = "minority_ack" /\ path = "Minority"
              /\ 1 \in submitted /\ 1 \notin settled;
        acknowledgements := acknowledgements \cup {1};
        view := "Applied";

      or
        \* Administrative recreation retains a fencing high-water mark and a
        \* non-reused incarnation. Reusing a native payload version permits
        \* ABA even when the owner label appears unchanged.
        await path = "Majority" /\ ~recreated;
        recreated := TRUE;
        if Mutation = "aba_reset" then
            authority := Initial;
        else
            authority := [incarnation |-> 2, revision |-> authority.revision + 1,
                           epoch |-> authority.epoch + 1, owner |-> "A"];
            highWater := authority.epoch;
        end if;

      or
        \* Metadata compaction cannot discard unsettled operation receipts or
        \* the fencing envelope. A retained result still reconciles afterward.
        await ~compacted /\ receiptFacts # {};
        compacted := TRUE;
        if Mutation = "forget_receipt" then
            with id \in Ids do
                await receipts[id].result # "Absent";
                receipts[id] := EmptyReceipt;
            end with;
        end if;

      or
        \* Isolation changes availability only. Healing may let an earlier
        \* timed-out submission settle. Unbounded stuttering is permitted.
        with connection \in {"Majority", "Minority", "Offline"} do
            path := connection;
        end with;
      end either;
    end while;
end algorithm; *)

\* BEGIN TRANSLATION
VARIABLES authority, highWater, recreated, reserved, receipts, receiptFacts,
          compacted, requests, submitted, settled, replies, primaryId, view,
          path, timeoutObserved, missingObserved, lostObserved, reconciled,
          reconciledAfterLoss, reconciledAfterCompaction, lateReply,
          conflictObserved, capacityRefused, acknowledgements,
          minoritySubmitted, minorityTimedOut, staleRejectedAfterRecreate,
          primaryCommits

vars == << authority, highWater, recreated, reserved, receipts, receiptFacts,
           compacted, requests, submitted, settled, replies, primaryId, view,
           path, timeoutObserved, missingObserved, lostObserved, reconciled,
           reconciledAfterLoss, reconciledAfterCompaction, lateReply,
           conflictObserved, capacityRefused, acknowledgements,
           minoritySubmitted, minorityTimedOut, staleRejectedAfterRecreate,
           primaryCommits >>

Init == (* Global variables *)
        /\ authority = Initial
        /\ highWater = 1
        /\ recreated = FALSE
        /\ reserved = {}
        /\ receipts = [id \in Ids |-> EmptyReceipt]
        /\ receiptFacts = {}
        /\ compacted = FALSE
        /\ requests = [slot \in Slots |-> EmptyRequest]
        /\ submitted = {}
        /\ settled = {}
        /\ replies = [slot \in Slots |-> "None"]
        /\ primaryId = 1
        /\ view = "Idle"
        /\ path = "Majority"
        /\ timeoutObserved = FALSE
        /\ missingObserved = FALSE
        /\ lostObserved = FALSE
        /\ reconciled = FALSE
        /\ reconciledAfterLoss = FALSE
        /\ reconciledAfterCompaction = FALSE
        /\ lateReply = FALSE
        /\ conflictObserved = FALSE
        /\ capacityRefused = FALSE
        /\ acknowledgements = {}
        /\ minoritySubmitted = FALSE
        /\ minorityTimedOut = FALSE
        /\ staleRejectedAfterRecreate = FALSE
        /\ primaryCommits = 0

Next == \/ /\ 1 \notin submitted
           /\ reserved' = (reserved \cup {1})
           /\ submitted' = (submitted \cup {1})
           /\ minoritySubmitted' = (path = "Minority")
           /\ view' = "Pending"
           /\ UNCHANGED <<authority, highWater, recreated, receipts, receiptFacts, compacted, requests, settled, replies, primaryId, path, timeoutObserved, missingObserved, lostObserved, reconciled, reconciledAfterLoss, reconciledAfterCompaction, lateReply, conflictObserved, capacityRefused, acknowledgements, minorityTimedOut, staleRejectedAfterRecreate, primaryCommits>>
        \/ /\ timeoutObserved /\ view = "Unknown" /\ 2 \notin submitted
           /\ IF Mutation = "retry_new_id" /\ Capacity = 2
                 THEN /\ primaryId' = 2
                      /\ reserved' = (reserved \cup {2})
                      /\ requests' = [requests EXCEPT ![2] = [id |-> 2, digest |-> 1, expected |-> authority,
                                                              purpose |-> "Primary"]]
                 ELSE /\ requests' = [requests EXCEPT ![2] = requests[1]]
                      /\ UNCHANGED << reserved, primaryId >>
           /\ submitted' = (submitted \cup {2})
           /\ UNCHANGED <<authority, highWater, recreated, receipts, receiptFacts, compacted, settled, replies, view, path, timeoutObserved, missingObserved, lostObserved, reconciled, reconciledAfterLoss, reconciledAfterCompaction, lateReply, conflictObserved, capacityRefused, acknowledgements, minoritySubmitted, minorityTimedOut, staleRejectedAfterRecreate, primaryCommits>>
        \/ /\ 1 \in submitted /\ 3 \notin submitted
           /\ \E kind \in {"Stale", "Conflict"}:
                IF kind = "Conflict"
                   THEN /\ requests' = [requests EXCEPT ![3] = [id |-> 1, digest |-> 2, expected |-> Initial,
                                                                purpose |-> "Other"]]
                        /\ submitted' = (submitted \cup {3})
                        /\ UNCHANGED << reserved, capacityRefused >>
                   ELSE /\ IF 2 \in reserved \/ Cardinality(reserved) < Capacity
                              THEN /\ reserved' = (reserved \cup {2})
                                   /\ requests' = [requests EXCEPT ![3] = [id |-> 2, digest |-> 1, expected |-> Initial,
                                                                           purpose |-> "Other"]]
                                   /\ submitted' = (submitted \cup {3})
                                   /\ UNCHANGED capacityRefused
                              ELSE /\ capacityRefused' = TRUE
                                   /\ UNCHANGED << reserved, requests,
                                                   submitted >>
           /\ UNCHANGED <<authority, highWater, recreated, receipts, receiptFacts, compacted, settled, replies, primaryId, view, path, timeoutObserved, missingObserved, lostObserved, reconciled, reconciledAfterLoss, reconciledAfterCompaction, lateReply, conflictObserved, acknowledgements, minoritySubmitted, minorityTimedOut, staleRejectedAfterRecreate, primaryCommits>>
        \/ /\ path = "Majority"
           /\ \E slot \in submitted \ settled:
                /\ IF requests[slot].digest # 1
                      THEN /\ replies' = [replies EXCEPT ![slot] = "Conflict"]
                           /\ conflictObserved' = TRUE
                           /\ UNCHANGED << authority, highWater, receipts,
                                           receiptFacts,
                                           staleRejectedAfterRecreate,
                                           primaryCommits >>
                      ELSE /\ IF receipts[requests[slot].id].result # "Absent"
                                 THEN /\ IF receipts[requests[slot].id].digest = requests[slot].digest
                                            THEN /\ replies' = [replies EXCEPT ![slot] = receipts[requests[slot].id].result]
                                                 /\ UNCHANGED conflictObserved
                                            ELSE /\ replies' = [replies EXCEPT ![slot] = "Conflict"]
                                                 /\ conflictObserved' = TRUE
                                      /\ UNCHANGED << authority, highWater,
                                                      receipts,
                                                      receiptFacts,
                                                      staleRejectedAfterRecreate,
                                                      primaryCommits >>
                                 ELSE /\ IF authority = requests[slot].expected
                                            THEN /\ authority' = [authority EXCEPT !.revision = @ + 1,
                                                                   !.epoch = @ + 1, !.owner = "B"]
                                                 /\ highWater' = authority'.epoch
                                                 /\ receipts' = [receipts EXCEPT ![requests[slot].id] =                            [digest |-> requests[slot].digest,
                                                                                                        result |-> "Applied", value |-> authority']]
                                                 /\ receiptFacts' = (receiptFacts \cup {<<requests[slot].id, receipts'[requests[slot].id]>>})
                                                 /\ replies' = [replies EXCEPT ![slot] = "Applied"]
                                                 /\ IF requests[slot].purpose = "Primary"
                                                       THEN /\ primaryCommits' = primaryCommits + 1
                                                       ELSE /\ TRUE
                                                            /\ UNCHANGED primaryCommits
                                                 /\ UNCHANGED staleRejectedAfterRecreate
                                            ELSE /\ receipts' = [receipts EXCEPT ![requests[slot].id] =                            [digest |-> requests[slot].digest,
                                                                                                        result |-> "Rejected", value |-> authority]]
                                                 /\ receiptFacts' = (receiptFacts \cup {<<requests[slot].id, receipts'[requests[slot].id]>>})
                                                 /\ replies' = [replies EXCEPT ![slot] = "Rejected"]
                                                 /\ IF slot = 3 /\ requests[slot].id = 2 /\ recreated
                                                       THEN /\ staleRejectedAfterRecreate' = TRUE
                                                       ELSE /\ TRUE
                                                            /\ UNCHANGED staleRejectedAfterRecreate
                                                 /\ UNCHANGED << authority,
                                                                 highWater,
                                                                 primaryCommits >>
                                      /\ UNCHANGED conflictObserved
                /\ settled' = (settled \cup {slot})
           /\ UNCHANGED <<recreated, reserved, compacted, requests, submitted, primaryId, view, path, timeoutObserved, missingObserved, lostObserved, reconciled, reconciledAfterLoss, reconciledAfterCompaction, lateReply, capacityRefused, acknowledgements, minoritySubmitted, minorityTimedOut>>
        \/ /\ 1 \in submitted /\ view \in {"Pending", "Unknown"}
           /\ timeoutObserved' = TRUE
           /\ IF path = "Minority" /\ 1 \notin settled
                 THEN /\ minorityTimedOut' = TRUE
                 ELSE /\ TRUE
                      /\ UNCHANGED minorityTimedOut
           /\ IF Mutation = "timeout_no_commit"
                 THEN /\ view' = "NoCommit"
                 ELSE /\ view' = "Unknown"
           /\ UNCHANGED <<authority, highWater, recreated, reserved, receipts, receiptFacts, compacted, requests, submitted, settled, replies, primaryId, path, missingObserved, lostObserved, reconciled, reconciledAfterLoss, reconciledAfterCompaction, lateReply, conflictObserved, capacityRefused, acknowledgements, minoritySubmitted, staleRejectedAfterRecreate, primaryCommits>>
        \/ /\ 1 \in submitted /\ path = "Majority"
           /\ IF receipts[primaryId].result = "Absent"
                 THEN /\ missingObserved' = TRUE
                      /\ view' = "Unknown"
                      /\ UNCHANGED << reconciled, reconciledAfterLoss,
                                      reconciledAfterCompaction >>
                 ELSE /\ view' = receipts[primaryId].result
                      /\ reconciled' = TRUE
                      /\ IF lostObserved
                            THEN /\ reconciledAfterLoss' = TRUE
                            ELSE /\ TRUE
                                 /\ UNCHANGED reconciledAfterLoss
                      /\ IF compacted
                            THEN /\ reconciledAfterCompaction' = TRUE
                            ELSE /\ TRUE
                                 /\ UNCHANGED reconciledAfterCompaction
                      /\ UNCHANGED missingObserved
           /\ UNCHANGED <<authority, highWater, recreated, reserved, receipts, receiptFacts, compacted, requests, submitted, settled, replies, primaryId, path, timeoutObserved, lostObserved, lateReply, conflictObserved, capacityRefused, acknowledgements, minoritySubmitted, minorityTimedOut, staleRejectedAfterRecreate, primaryCommits>>
        \/ /\ \E slot \in settled:
                /\ replies[slot] \in {"Applied", "Rejected", "Conflict"}
                /\ IF requests[slot].purpose = "Primary" /\ replies[slot] = "Applied"
                      THEN /\ lostObserved' = TRUE
                      ELSE /\ TRUE
                           /\ UNCHANGED lostObserved
                /\ replies' = [replies EXCEPT ![slot] = "Lost"]
           /\ UNCHANGED <<authority, highWater, recreated, reserved, receipts, receiptFacts, compacted, requests, submitted, settled, primaryId, view, path, timeoutObserved, missingObserved, reconciled, reconciledAfterLoss, reconciledAfterCompaction, lateReply, conflictObserved, capacityRefused, acknowledgements, minoritySubmitted, minorityTimedOut, staleRejectedAfterRecreate, primaryCommits>>
        \/ /\ path # "Offline"
           /\ \E slot \in settled:
                /\ replies[slot] \in {"Applied", "Rejected"}
                   /\ requests[slot].purpose = "Primary"
                /\ acknowledgements' = (acknowledgements \cup {slot})
                /\ view' = replies[slot]
                /\ lateReply' = timeoutObserved
                /\ replies' = [replies EXCEPT ![slot] = "Delivered"]
           /\ UNCHANGED <<authority, highWater, recreated, reserved, receipts, receiptFacts, compacted, requests, submitted, settled, primaryId, path, timeoutObserved, missingObserved, lostObserved, reconciled, reconciledAfterLoss, reconciledAfterCompaction, conflictObserved, capacityRefused, minoritySubmitted, minorityTimedOut, staleRejectedAfterRecreate, primaryCommits>>
        \/ /\ Mutation = "minority_ack" /\ path = "Minority"
              /\ 1 \in submitted /\ 1 \notin settled
           /\ acknowledgements' = (acknowledgements \cup {1})
           /\ view' = "Applied"
           /\ UNCHANGED <<authority, highWater, recreated, reserved, receipts, receiptFacts, compacted, requests, submitted, settled, replies, primaryId, path, timeoutObserved, missingObserved, lostObserved, reconciled, reconciledAfterLoss, reconciledAfterCompaction, lateReply, conflictObserved, capacityRefused, minoritySubmitted, minorityTimedOut, staleRejectedAfterRecreate, primaryCommits>>
        \/ /\ path = "Majority" /\ ~recreated
           /\ recreated' = TRUE
           /\ IF Mutation = "aba_reset"
                 THEN /\ authority' = Initial
                      /\ UNCHANGED highWater
                 ELSE /\ authority' = [incarnation |-> 2, revision |-> authority.revision + 1,
                                        epoch |-> authority.epoch + 1, owner |-> "A"]
                      /\ highWater' = authority'.epoch
           /\ UNCHANGED <<reserved, receipts, receiptFacts, compacted, requests, submitted, settled, replies, primaryId, view, path, timeoutObserved, missingObserved, lostObserved, reconciled, reconciledAfterLoss, reconciledAfterCompaction, lateReply, conflictObserved, capacityRefused, acknowledgements, minoritySubmitted, minorityTimedOut, staleRejectedAfterRecreate, primaryCommits>>
        \/ /\ ~compacted /\ receiptFacts # {}
           /\ compacted' = TRUE
           /\ IF Mutation = "forget_receipt"
                 THEN /\ \E id \in Ids:
                           /\ receipts[id].result # "Absent"
                           /\ receipts' = [receipts EXCEPT ![id] = EmptyReceipt]
                 ELSE /\ TRUE
                      /\ UNCHANGED receipts
           /\ UNCHANGED <<authority, highWater, recreated, reserved, receiptFacts, requests, submitted, settled, replies, primaryId, view, path, timeoutObserved, missingObserved, lostObserved, reconciled, reconciledAfterLoss, reconciledAfterCompaction, lateReply, conflictObserved, capacityRefused, acknowledgements, minoritySubmitted, minorityTimedOut, staleRejectedAfterRecreate, primaryCommits>>
        \/ /\ \E connection \in {"Majority", "Minority", "Offline"}:
                path' = connection
           /\ UNCHANGED <<authority, highWater, recreated, reserved, receipts, receiptFacts, compacted, requests, submitted, settled, replies, primaryId, view, timeoutObserved, missingObserved, lostObserved, reconciled, reconciledAfterLoss, reconciledAfterCompaction, lateReply, conflictObserved, capacityRefused, acknowledgements, minoritySubmitted, minorityTimedOut, staleRejectedAfterRecreate, primaryCommits>>

Spec == Init /\ [][Next]_vars

\* END TRANSLATION

TypeOK ==
    /\ authority \in [incarnation : 1..2, revision : 1..4,
                       epoch : 1..4, owner : {"A", "B"}]
    /\ highWater \in 1..4 /\ recreated \in BOOLEAN
    /\ reserved \subseteq Ids /\ submitted \subseteq Slots
    /\ settled \subseteq submitted
    /\ receipts \in [Ids -> [digest : 0..2,
                       result : {"Absent", "Applied", "Rejected"},
                       value : [incarnation : 1..2, revision : 1..4,
                                epoch : 1..4, owner : {"A", "B"}]]]
    /\ requests \in [Slots -> [id : Ids, digest : 1..2,
                       expected : [incarnation : 1..2, revision : 1..4,
                                   epoch : 1..4, owner : {"A", "B"}],
                       purpose : {"Primary", "Other"}]]
    /\ replies \in [Slots -> {"None", "Applied", "Rejected", "Conflict",
                              "Lost", "Delivered"}]
    /\ primaryId \in Ids
    /\ view \in {"Idle", "Pending", "Unknown", "Applied", "Rejected", "NoCommit"}
    /\ path \in {"Majority", "Minority", "Offline"}
    /\ timeoutObserved \in BOOLEAN /\ missingObserved \in BOOLEAN
    /\ lostObserved \in BOOLEAN /\ reconciled \in BOOLEAN
    /\ reconciledAfterLoss \in BOOLEAN /\ reconciledAfterCompaction \in BOOLEAN
    /\ lateReply \in BOOLEAN /\ conflictObserved \in BOOLEAN
    /\ capacityRefused \in BOOLEAN /\ acknowledgements \subseteq Slots
    /\ primaryCommits \in 0..2
    /\ receiptFacts \subseteq (Ids \X [digest : 1..2,
                       result : {"Applied", "Rejected"},
                       value : [incarnation : 1..2, revision : 1..4,
                                epoch : 1..4, owner : {"A", "B"}]])
    /\ compacted \in BOOLEAN /\ minoritySubmitted \in BOOLEAN
    /\ minorityTimedOut \in BOOLEAN /\ staleRejectedAfterRecreate \in BOOLEAN

CapacityReserved == /\ Cardinality(reserved) <= Capacity
                    /\ \A slot \in submitted : requests[slot].id \in reserved
                    /\ \A id \in Ids : receipts[id].result # "Absent"
                                         => id \in reserved
StableOperationId == /\ primaryId = 1
                     /\ 2 \in submitted => requests[2] = requests[1]
ReceiptRetained == \A fact \in receiptFacts : receipts[fact[1]] = fact[2]
OneLogicalCommit == primaryCommits <= 1
NoFalseNoCommit == view = "NoCommit" => receipts[1].result # "Applied"
NoMinorityAck == \A slot \in acknowledgements :
    /\ slot \in settled
    /\ receipts[requests[slot].id].result \in {"Applied", "Rejected"}
    /\ receipts[requests[slot].id].digest = requests[slot].digest
MonotonicFence == /\ authority.epoch = highWater
                  /\ authority.revision = highWater
                  /\ \A id \in Ids : receipts[id].result # "Absent"
                       => receipts[id].value.epoch <= authority.epoch
ResultHasReceipt == view \in {"Applied", "Rejected"}
                    => receipts[primaryId].result = view
NoReusedIncarnation == recreated => authority.incarnation = 2

\* Positive controls negate meaningful schedules while retaining all safety
\* invariants. Their expected counterexamples demonstrate non-vacuity only.
NoUnknownCommit == ~(timeoutObserved /\ receipts[1].result = "Applied"
                     /\ view = "Unknown")
NoMissingThenCommit == ~(missingObserved /\ receipts[1].result = "Applied")
NoLostReconciliation == ~(lostObserved /\ reconciledAfterLoss
                         /\ receipts[1].result = "Applied" /\ view = "Applied")
NoLateReply == ~lateReply
NoStaleRejection == ~staleRejectedAfterRecreate
NoMinorityThenHeal == ~(minoritySubmitted /\ minorityTimedOut
                       /\ receipts[1].result = "Applied")
NoCompactedReconciliation == ~(compacted /\ reconciledAfterCompaction
                              /\ receipts[1].result = "Applied" /\ view = "Applied")
NoDigestConflict == ~conflictObserved
NoCapacityRefusal == ~capacityRefused
=============================================================================
