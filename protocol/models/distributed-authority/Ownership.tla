---------------------------- MODULE Ownership ----------------------------
EXTENDS Naturals, FiniteSets, TLC

\* This first-wave model separates the authority record from local writer
\* custody. A committed directory update cannot stop a source writer, and a
\* local freeze can survive while its directory publication is still absent.
\* One nondeterministic scheduler interleaves atomic durability boundaries;
\* it does not make the entire handoff atomic. See README.md for the bounds
\* and for the implementation obligations these abstract steps leave open.

CONSTANT Mutation, MaxHandoffs
Nodes == {"A", "B"}
Executors == {"E1", "E2"}
Actors == Nodes \cup Executors
SourceGrant == <<"A", 1>>
TargetGrant == <<"B", 2>>
Phases == {"Active", "Draining", "Frozen", "Prepared"}

ASSUME /\ MaxHandoffs \in 1..2
       /\ Mutation \in {"none", "directory_freeze", "late_admission",
                         "unverified_cut"}

(* --algorithm PlannedHandoff
variables
    \* The directory is durable and serialized, but its replies are separate
    \* observations. The handoff identity stays attached through activation.
    directory = [phase |-> "Active", owner |-> "A", epoch |-> 1, h |-> 0],
    intent = 0,
    lastId = 0,
    aborted = {},
    sourceView = "Unknown",
    targetIntent = 0,
    targetView = "Unknown",
    lostActivationReply = FALSE,

    \* The local seal serializes cancellation with freezing. An abort first
    \* seals out freeze locally; mere absence of a directory freeze is unsafe.
    seal = "Open",
    cut = "Absent",
    targetVerified = FALSE,
    writers = {SourceGrant},

    \* Each executor retains its admission fence and retirement receipt over
    \* restart. Pending requests can arrive after the receipt was acknowledged.
    requests = [x \in Executors |-> "Unsent"],
    closed = {},
    acknowledged = {},

    \* A crash loses writer handles and observations, not durable evidence or
    \* native work. A partition loses communication only, never grants authority.
    alive = Actors,
    partition = "None",
    route = "A",
    routeRejected = FALSE,
    recoveredFreeze = FALSE;

define
    Online(actor) == partition # actor /\ partition # "Directory"
    SourceMayOpen == /\ directory.owner = "A"
                     /\ directory.epoch = 1
                     /\ directory.phase \in {"Active", "Draining"}
                     /\ seal # "Frozen"
    Running == {x \in Executors : requests[x] = "Running"}
end define;

begin
Step:
    while TRUE do
      either
        \* Persist intent before submission. Lost replies and restart cannot
        \* manufacture a new identity for an unresolved handoff.
        await "A" \in alive /\ directory.phase = "Active"
              /\ directory.owner = "A" /\ intent = 0
              /\ seal # "Frozen" /\ lastId < MaxHandoffs;
        lastId := lastId + 1;
        intent := lastId;
        seal := "Open";
        sourceView := "Unknown";

      or
        \* Conditional publication is one metadata commit. The caller still
        \* has an unknown outcome until it reads the retained handoff identity.
        await "A" \in alive /\ Online("A") /\ intent > 0
              /\ directory.phase = "Active" /\ directory.owner = "A"
              /\ intent \notin aborted /\ seal = "Open";
        directory := [phase |-> "Draining", owner |-> "A",
                      epoch |-> 1, h |-> intent];

      or
        \* Reconciliation reads the same intent, including an abort receipt.
        \* Observing a later phase never changes the identity of that intent.
        await "A" \in alive /\ Online("A") /\ intent > 0;
        if intent \in aborted then
            sourceView := "Aborted";
        elsif directory.h = intent then
            sourceView := directory.phase;
        end if;

      or
        \* The source participates in cancellation before the metadata abort.
        \* This durable seal makes a subsequent freeze impossible for this ID.
        await "A" \in alive /\ directory.phase = "Draining"
              /\ directory.h = intent /\ seal = "Open";
        seal := "Cancelled";

      or
        \* An abort publication may also lose its reply. Keep a receipt so
        \* reconciliation can retire exactly this intent before another starts.
        await "A" \in alive /\ Online("A")
              /\ directory.phase = "Draining" /\ directory.h = intent
              /\ seal = "Cancelled";
        aborted := aborted \cup {intent};
        directory := [phase |-> "Active", owner |-> "A",
                      epoch |-> 1, h |-> 0];

      or
        await "A" \in alive /\ sourceView = "Aborted"
              /\ intent \in aborted;
        intent := 0;
        sourceView := "Unknown";

      or
        \* Local freeze permanently forbids reopening epoch 1 before the
        \* directory knows about it. Crash here is the interrupted-freeze case.
        await "A" \in alive /\ directory.phase = "Draining"
              /\ directory.h = intent /\ sourceView = "Draining"
              /\ seal = "Open";
        seal := "Frozen";
        writers := writers \ {SourceGrant};

      or
        \* The consistent cut abstracts a closed writer, a WAL-aware backup,
        \* its manifest, and source validation. It is not a live .db copy.
        await "A" \in alive /\ seal = "Frozen" /\ cut = "Absent";
        cut := "Consistent";

      or
        \* M1 deliberately treats directory publication as physical freeze.
        \* It fabricates a cut without closing A, exposing cross-epoch writers.
        await "A" \in alive /\ Online("A")
              /\ directory.phase = "Draining" /\ directory.h = intent
              /\ ( (seal = "Frozen" /\ cut = "Consistent")
                   \/ (Mutation = "directory_freeze" /\ seal = "Open") );
        directory := [directory EXCEPT !.phase = "Frozen"];
        cut := "Consistent";

      or
        \* B journals the received handoff before preparing a metadata attempt.
        \* Its volatile observation can be lost while this identity survives.
        await "B" \in alive /\ Online("B")
              /\ directory.phase = "Frozen" /\ targetIntent = 0;
        targetIntent := directory.h;
        targetView := "Frozen";

      or
        \* Read-back reconciles preparation and activation replies by the same
        \* journaled ID. Neither an unknown reply nor restart invents a new ID.
        await "B" \in alive /\ Online("B") /\ targetIntent > 0
              /\ directory.h = targetIntent;
        targetView := directory.phase;

      or
        \* B verifies identity, digest, and required artifacts independently
        \* of publication. Verification may be retried without a fresh ID.
        await "B" \in alive /\ Online("B")
              /\ directory.phase = "Frozen" /\ cut = "Consistent"
              /\ targetIntent = directory.h;
        targetVerified := TRUE;

      or
        \* Closing admission does not retire native work. It rejects future
        \* deliveries even if they were sent while A still held its grant.
        with x \in Executors do
            await x \in alive /\ Online(x)
                  /\ directory.phase \in {"Frozen", "Prepared"};
            closed := closed \cup {x};
        end with;

      or
        \* Retirement evidence follows native cleanup and durable closure.
        \* A request still in transport is safe only because closure persists.
        with x \in Executors do
            await x \in alive /\ Online(x) /\ x \in closed
                  /\ requests[x] # "Running";
            acknowledged := acknowledged \cup {x};
        end with;

      or
        \* Prepared carries the target's verification plus every relevant
        \* executor's acknowledgement. M3 skips only target verification.
        await "B" \in alive /\ Online("B")
              /\ directory.phase = "Frozen" /\ targetIntent = directory.h
              /\ acknowledged = Executors
              /\ (targetVerified \/ Mutation = "unverified_cut");
        directory := [phase |-> "Prepared", owner |-> "B",
                      epoch |-> 2, h |-> intent];

      or
        \* Activation is a metadata commit, not acquisition of a writer.
        \* If its reply is lost, B reads this same handoff and epoch on retry.
        await "B" \in alive /\ Online("B")
              /\ directory.phase = "Prepared" /\ targetView = "Prepared"
              /\ targetIntent = directory.h;
        directory := [directory EXCEPT !.phase = "Active"];

      or
        \* Startup always rereads authority and the local durable seal.
        \* A copied lease, cached route, or missing reply cannot reopen A.
        await "A" \in alive /\ Online("A") /\ SourceMayOpen;
        writers := writers \cup {SourceGrant};

      or
        await "B" \in alive /\ Online("B")
              /\ directory.phase = "Active" /\ directory.owner = "B"
              /\ directory.epoch = 2 /\ directory.h = targetIntent
              /\ targetView = "Active";
        writers := writers \cup {TargetGrant};

      or
        \* Only an active source can originate a bounded request. Its delivery
        \* is a different step, so draining can overtake the message in flight.
        with x \in Executors do
            await "A" \in alive /\ Online("A")
                  /\ directory.phase = "Active" /\ directory.owner = "A"
                  /\ SourceGrant \in writers /\ requests[x] = "Unsent";
            requests[x] := "Pending";
        end with;

      or
        \* M2 admits delayed epoch-1 requests despite durable closure. This can
        \* restore native mutation authority after B starts in epoch 2.
        with x \in Executors do
            await x \in alive /\ Online(x) /\ requests[x] = "Pending";
            if x \notin closed \/ Mutation = "late_admission" then
                requests[x] := "Running";
            else
                requests[x] := "Rejected";
            end if;
        end with;

      or
        \* A crash is not cleanup. Only this explicit native-retirement event
        \* settles a running request; its outcome is outside D1's boundary.
        with x \in Executors do
            await x \in alive /\ requests[x] = "Running";
            requests[x] := "Retired";
        end with;

      or
        \* A stale route attempts ingress without constructing a grant. The
        \* authoritative recipient refuses it after ownership moves to B.
        await route = "A" /\ "A" \in alive /\ Online("A")
              /\ directory.owner = "B";
        routeRejected := TRUE;

      or
        await directory.phase = "Active" /\ Online(directory.owner);
        route := directory.owner;

      or
        \* Crashes preserve executor fences, native custody, intent, and seals.
        \* Losing a writer handle permits recovery, never a second owner.
        with actor \in alive do
            alive := alive \ {actor};
            writers := {w \in writers : w[1] # actor};
            if actor = "A" then sourceView := "Unknown"; end if;
            if actor = "B" then
                if directory.owner = "B" /\ directory.phase = "Active"
                   /\ targetView # "Active" then
                    lostActivationReply := TRUE;
                end if;
                targetView := "Unknown";
            end if;
        end with;

      or
        \* Recovery reconstructs observations separately from writer acquisition.
        \* The witness flag records restart before freeze publication reached
        \* the directory; it has no influence on any protocol transition.
        with actor \in Actors \ alive do
            alive := alive \cup {actor};
            if actor = "A" /\ seal = "Frozen"
               /\ directory.phase = "Draining" then
                recoveredFreeze := TRUE;
            end if;
        end with;

      or
        \* No transition interprets isolation as death. The network may stay
        \* partitioned forever; safety needs no fairness or eventual delivery.
        with unavailable \in Actors \cup {"None", "Directory"} do
            partition := unavailable;
        end with;
      end either;
    end while;
end algorithm; *)

\* The generated translation lives here. run.py checks it byte for byte
\* against the pinned PlusCal translator before checking any model.

\* BEGIN TRANSLATION
VARIABLES directory, intent, lastId, aborted, sourceView, targetIntent,
          targetView, lostActivationReply, seal, cut, targetVerified, writers,
          requests, closed, acknowledged, alive, partition, route,
          routeRejected, recoveredFreeze

(* define statement *)
Online(actor) == partition # actor /\ partition # "Directory"
SourceMayOpen == /\ directory.owner = "A"
                 /\ directory.epoch = 1
                 /\ directory.phase \in {"Active", "Draining"}
                 /\ seal # "Frozen"
Running == {x \in Executors : requests[x] = "Running"}


vars == << directory, intent, lastId, aborted, sourceView, targetIntent,
           targetView, lostActivationReply, seal, cut, targetVerified,
           writers, requests, closed, acknowledged, alive, partition, route,
           routeRejected, recoveredFreeze >>

Init == (* Global variables *)
        /\ directory = [phase |-> "Active", owner |-> "A", epoch |-> 1, h |-> 0]
        /\ intent = 0
        /\ lastId = 0
        /\ aborted = {}
        /\ sourceView = "Unknown"
        /\ targetIntent = 0
        /\ targetView = "Unknown"
        /\ lostActivationReply = FALSE
        /\ seal = "Open"
        /\ cut = "Absent"
        /\ targetVerified = FALSE
        /\ writers = {SourceGrant}
        /\ requests = [x \in Executors |-> "Unsent"]
        /\ closed = {}
        /\ acknowledged = {}
        /\ alive = Actors
        /\ partition = "None"
        /\ route = "A"
        /\ routeRejected = FALSE
        /\ recoveredFreeze = FALSE

Next == \/ /\ "A" \in alive /\ directory.phase = "Active"
              /\ directory.owner = "A" /\ intent = 0
              /\ seal # "Frozen" /\ lastId < MaxHandoffs
           /\ lastId' = lastId + 1
           /\ intent' = lastId'
           /\ seal' = "Open"
           /\ sourceView' = "Unknown"
           /\ UNCHANGED <<directory, aborted, targetIntent, targetView, lostActivationReply, cut, targetVerified, writers, requests, closed, acknowledged, alive, partition, route, routeRejected, recoveredFreeze>>
        \/ /\ "A" \in alive /\ Online("A") /\ intent > 0
              /\ directory.phase = "Active" /\ directory.owner = "A"
              /\ intent \notin aborted /\ seal = "Open"
           /\ directory' = [phase |-> "Draining", owner |-> "A",
                            epoch |-> 1, h |-> intent]
           /\ UNCHANGED <<intent, lastId, aborted, sourceView, targetIntent, targetView, lostActivationReply, seal, cut, targetVerified, writers, requests, closed, acknowledged, alive, partition, route, routeRejected, recoveredFreeze>>
        \/ /\ "A" \in alive /\ Online("A") /\ intent > 0
           /\ IF intent \in aborted
                 THEN /\ sourceView' = "Aborted"
                 ELSE /\ IF directory.h = intent
                            THEN /\ sourceView' = directory.phase
                            ELSE /\ TRUE
                                 /\ UNCHANGED sourceView
           /\ UNCHANGED <<directory, intent, lastId, aborted, targetIntent, targetView, lostActivationReply, seal, cut, targetVerified, writers, requests, closed, acknowledged, alive, partition, route, routeRejected, recoveredFreeze>>
        \/ /\ "A" \in alive /\ directory.phase = "Draining"
              /\ directory.h = intent /\ seal = "Open"
           /\ seal' = "Cancelled"
           /\ UNCHANGED <<directory, intent, lastId, aborted, sourceView, targetIntent, targetView, lostActivationReply, cut, targetVerified, writers, requests, closed, acknowledged, alive, partition, route, routeRejected, recoveredFreeze>>
        \/ /\ "A" \in alive /\ Online("A")
              /\ directory.phase = "Draining" /\ directory.h = intent
              /\ seal = "Cancelled"
           /\ aborted' = (aborted \cup {intent})
           /\ directory' = [phase |-> "Active", owner |-> "A",
                            epoch |-> 1, h |-> 0]
           /\ UNCHANGED <<intent, lastId, sourceView, targetIntent, targetView, lostActivationReply, seal, cut, targetVerified, writers, requests, closed, acknowledged, alive, partition, route, routeRejected, recoveredFreeze>>
        \/ /\ "A" \in alive /\ sourceView = "Aborted"
              /\ intent \in aborted
           /\ intent' = 0
           /\ sourceView' = "Unknown"
           /\ UNCHANGED <<directory, lastId, aborted, targetIntent, targetView, lostActivationReply, seal, cut, targetVerified, writers, requests, closed, acknowledged, alive, partition, route, routeRejected, recoveredFreeze>>
        \/ /\ "A" \in alive /\ directory.phase = "Draining"
              /\ directory.h = intent /\ sourceView = "Draining"
              /\ seal = "Open"
           /\ seal' = "Frozen"
           /\ writers' = writers \ {SourceGrant}
           /\ UNCHANGED <<directory, intent, lastId, aborted, sourceView, targetIntent, targetView, lostActivationReply, cut, targetVerified, requests, closed, acknowledged, alive, partition, route, routeRejected, recoveredFreeze>>
        \/ /\ "A" \in alive /\ seal = "Frozen" /\ cut = "Absent"
           /\ cut' = "Consistent"
           /\ UNCHANGED <<directory, intent, lastId, aborted, sourceView, targetIntent, targetView, lostActivationReply, seal, targetVerified, writers, requests, closed, acknowledged, alive, partition, route, routeRejected, recoveredFreeze>>
        \/ /\ "A" \in alive /\ Online("A")
              /\ directory.phase = "Draining" /\ directory.h = intent
              /\ ( (seal = "Frozen" /\ cut = "Consistent")
                   \/ (Mutation = "directory_freeze" /\ seal = "Open") )
           /\ directory' = [directory EXCEPT !.phase = "Frozen"]
           /\ cut' = "Consistent"
           /\ UNCHANGED <<intent, lastId, aborted, sourceView, targetIntent, targetView, lostActivationReply, seal, targetVerified, writers, requests, closed, acknowledged, alive, partition, route, routeRejected, recoveredFreeze>>
        \/ /\ "B" \in alive /\ Online("B")
              /\ directory.phase = "Frozen" /\ targetIntent = 0
           /\ targetIntent' = directory.h
           /\ targetView' = "Frozen"
           /\ UNCHANGED <<directory, intent, lastId, aborted, sourceView, lostActivationReply, seal, cut, targetVerified, writers, requests, closed, acknowledged, alive, partition, route, routeRejected, recoveredFreeze>>
        \/ /\ "B" \in alive /\ Online("B") /\ targetIntent > 0
              /\ directory.h = targetIntent
           /\ targetView' = directory.phase
           /\ UNCHANGED <<directory, intent, lastId, aborted, sourceView, targetIntent, lostActivationReply, seal, cut, targetVerified, writers, requests, closed, acknowledged, alive, partition, route, routeRejected, recoveredFreeze>>
        \/ /\ "B" \in alive /\ Online("B")
              /\ directory.phase = "Frozen" /\ cut = "Consistent"
              /\ targetIntent = directory.h
           /\ targetVerified' = TRUE
           /\ UNCHANGED <<directory, intent, lastId, aborted, sourceView, targetIntent, targetView, lostActivationReply, seal, cut, writers, requests, closed, acknowledged, alive, partition, route, routeRejected, recoveredFreeze>>
        \/ /\ \E x \in Executors:
                /\ x \in alive /\ Online(x)
                   /\ directory.phase \in {"Frozen", "Prepared"}
                /\ closed' = (closed \cup {x})
           /\ UNCHANGED <<directory, intent, lastId, aborted, sourceView, targetIntent, targetView, lostActivationReply, seal, cut, targetVerified, writers, requests, acknowledged, alive, partition, route, routeRejected, recoveredFreeze>>
        \/ /\ \E x \in Executors:
                /\ x \in alive /\ Online(x) /\ x \in closed
                   /\ requests[x] # "Running"
                /\ acknowledged' = (acknowledged \cup {x})
           /\ UNCHANGED <<directory, intent, lastId, aborted, sourceView, targetIntent, targetView, lostActivationReply, seal, cut, targetVerified, writers, requests, closed, alive, partition, route, routeRejected, recoveredFreeze>>
        \/ /\ "B" \in alive /\ Online("B")
              /\ directory.phase = "Frozen" /\ targetIntent = directory.h
              /\ acknowledged = Executors
              /\ (targetVerified \/ Mutation = "unverified_cut")
           /\ directory' = [phase |-> "Prepared", owner |-> "B",
                            epoch |-> 2, h |-> intent]
           /\ UNCHANGED <<intent, lastId, aborted, sourceView, targetIntent, targetView, lostActivationReply, seal, cut, targetVerified, writers, requests, closed, acknowledged, alive, partition, route, routeRejected, recoveredFreeze>>
        \/ /\ "B" \in alive /\ Online("B")
              /\ directory.phase = "Prepared" /\ targetView = "Prepared"
              /\ targetIntent = directory.h
           /\ directory' = [directory EXCEPT !.phase = "Active"]
           /\ UNCHANGED <<intent, lastId, aborted, sourceView, targetIntent, targetView, lostActivationReply, seal, cut, targetVerified, writers, requests, closed, acknowledged, alive, partition, route, routeRejected, recoveredFreeze>>
        \/ /\ "A" \in alive /\ Online("A") /\ SourceMayOpen
           /\ writers' = (writers \cup {SourceGrant})
           /\ UNCHANGED <<directory, intent, lastId, aborted, sourceView, targetIntent, targetView, lostActivationReply, seal, cut, targetVerified, requests, closed, acknowledged, alive, partition, route, routeRejected, recoveredFreeze>>
        \/ /\ "B" \in alive /\ Online("B")
              /\ directory.phase = "Active" /\ directory.owner = "B"
              /\ directory.epoch = 2 /\ directory.h = targetIntent
              /\ targetView = "Active"
           /\ writers' = (writers \cup {TargetGrant})
           /\ UNCHANGED <<directory, intent, lastId, aborted, sourceView, targetIntent, targetView, lostActivationReply, seal, cut, targetVerified, requests, closed, acknowledged, alive, partition, route, routeRejected, recoveredFreeze>>
        \/ /\ \E x \in Executors:
                /\ "A" \in alive /\ Online("A")
                   /\ directory.phase = "Active" /\ directory.owner = "A"
                   /\ SourceGrant \in writers /\ requests[x] = "Unsent"
                /\ requests' = [requests EXCEPT ![x] = "Pending"]
           /\ UNCHANGED <<directory, intent, lastId, aborted, sourceView, targetIntent, targetView, lostActivationReply, seal, cut, targetVerified, writers, closed, acknowledged, alive, partition, route, routeRejected, recoveredFreeze>>
        \/ /\ \E x \in Executors:
                /\ x \in alive /\ Online(x) /\ requests[x] = "Pending"
                /\ IF x \notin closed \/ Mutation = "late_admission"
                      THEN /\ requests' = [requests EXCEPT ![x] = "Running"]
                      ELSE /\ requests' = [requests EXCEPT ![x] = "Rejected"]
           /\ UNCHANGED <<directory, intent, lastId, aborted, sourceView, targetIntent, targetView, lostActivationReply, seal, cut, targetVerified, writers, closed, acknowledged, alive, partition, route, routeRejected, recoveredFreeze>>
        \/ /\ \E x \in Executors:
                /\ x \in alive /\ requests[x] = "Running"
                /\ requests' = [requests EXCEPT ![x] = "Retired"]
           /\ UNCHANGED <<directory, intent, lastId, aborted, sourceView, targetIntent, targetView, lostActivationReply, seal, cut, targetVerified, writers, closed, acknowledged, alive, partition, route, routeRejected, recoveredFreeze>>
        \/ /\ route = "A" /\ "A" \in alive /\ Online("A")
              /\ directory.owner = "B"
           /\ routeRejected' = TRUE
           /\ UNCHANGED <<directory, intent, lastId, aborted, sourceView, targetIntent, targetView, lostActivationReply, seal, cut, targetVerified, writers, requests, closed, acknowledged, alive, partition, route, recoveredFreeze>>
        \/ /\ directory.phase = "Active" /\ Online(directory.owner)
           /\ route' = directory.owner
           /\ UNCHANGED <<directory, intent, lastId, aborted, sourceView, targetIntent, targetView, lostActivationReply, seal, cut, targetVerified, writers, requests, closed, acknowledged, alive, partition, routeRejected, recoveredFreeze>>
        \/ /\ \E actor \in alive:
                /\ alive' = alive \ {actor}
                /\ writers' = {w \in writers : w[1] # actor}
                /\ IF actor = "A"
                      THEN /\ sourceView' = "Unknown"
                      ELSE /\ TRUE
                           /\ UNCHANGED sourceView
                /\ IF actor = "B"
                      THEN /\ IF directory.owner = "B" /\ directory.phase = "Active"
                                 /\ targetView # "Active"
                                 THEN /\ lostActivationReply' = TRUE
                                 ELSE /\ TRUE
                                      /\ UNCHANGED lostActivationReply
                           /\ targetView' = "Unknown"
                      ELSE /\ TRUE
                           /\ UNCHANGED << targetView, lostActivationReply >>
           /\ UNCHANGED <<directory, intent, lastId, aborted, targetIntent, seal, cut, targetVerified, requests, closed, acknowledged, partition, route, routeRejected, recoveredFreeze>>
        \/ /\ \E actor \in Actors \ alive:
                /\ alive' = (alive \cup {actor})
                /\ IF actor = "A" /\ seal = "Frozen"
                      /\ directory.phase = "Draining"
                      THEN /\ recoveredFreeze' = TRUE
                      ELSE /\ TRUE
                           /\ UNCHANGED recoveredFreeze
           /\ UNCHANGED <<directory, intent, lastId, aborted, sourceView, targetIntent, targetView, lostActivationReply, seal, cut, targetVerified, writers, requests, closed, acknowledged, partition, route, routeRejected>>
        \/ /\ \E unavailable \in Actors \cup {"None", "Directory"}:
                partition' = unavailable
           /\ UNCHANGED <<directory, intent, lastId, aborted, sourceView, targetIntent, targetView, lostActivationReply, seal, cut, targetVerified, writers, requests, closed, acknowledged, alive, route, routeRejected, recoveredFreeze>>

Spec == Init /\ [][Next]_vars

\* END TRANSLATION

\* These predicates inspect both local custody and directory state. Counting
\* owners separately by epoch would miss exactly the defect D1 must reject.
TypeOK ==
    /\ directory \in [phase : Phases, owner : Nodes, epoch : 1..2,
                       h : 0..MaxHandoffs]
    /\ intent \in 0..MaxHandoffs /\ lastId \in 0..MaxHandoffs
    /\ aborted \subseteq 1..MaxHandoffs
    /\ sourceView \in Phases \cup {"Unknown", "Aborted"}
    /\ targetIntent \in 0..MaxHandoffs
    /\ targetView \in Phases \cup {"Unknown"}
    /\ lostActivationReply \in BOOLEAN
    /\ seal \in {"Open", "Cancelled", "Frozen"}
    /\ cut \in {"Absent", "Consistent"}
    /\ targetVerified \in BOOLEAN
    /\ writers \subseteq {SourceGrant, TargetGrant}
    /\ requests \in [Executors -> {"Unsent", "Pending", "Running",
                                    "Retired", "Rejected"}]
    /\ closed \subseteq Executors /\ acknowledged \subseteq Executors
    /\ alive \subseteq Actors
    /\ partition \in Actors \cup {"None", "Directory"}
    /\ route \in Nodes /\ routeRejected \in BOOLEAN
    /\ recoveredFreeze \in BOOLEAN

OneEffectiveWriter == Cardinality(writers) <= 1

\* Native mutation authority remains effective while the executor is down or
\* partitioned. A lost monitor must never remove it from this union.
EffectiveAuthorities == writers \cup
    IF Running # {} THEN {SourceGrant} ELSE {}
NoOverlappingAuthority == Cardinality(EffectiveAuthorities) <= 1

\* The source epoch stays closed locally after freeze, regardless of whether
\* publication succeeded. A pre-freeze abort uses a cancellation seal instead.
NoEpochReuse == seal = "Frozen" => SourceGrant \notin writers
FrozenPublicationSound == directory.phase \in {"Frozen", "Prepared"}
                          => seal = "Frozen" /\ cut = "Consistent"

\* Activation requires all three independently established facts. Closure and
\* retirement receipts also remain sound after a delayed request is delivered.
ActivationHasEvidence ==
    directory.owner = "B" /\ directory.phase = "Active" =>
    /\ seal = "Frozen" /\ cut = "Consistent" /\ targetVerified
    /\ acknowledged = Executors /\ closed = Executors /\ Running = {}
AcknowledgementsSound == /\ acknowledged \subseteq closed
                         /\ acknowledged \cap Running = {}
SameHandoff == /\ directory.h > 0 => directory.h = intent
               /\ targetIntent > 0 => targetIntent = intent
                                        /\ targetIntent = directory.h
               /\ intent > 0 => intent <= lastId
               /\ directory.h > 0 => directory.h \notin aborted
WriterHasGrant ==
    /\ SourceGrant \in writers => SourceMayOpen
    /\ TargetGrant \in writers => directory.owner = "B"
                                 /\ directory.epoch = 2
                                 /\ directory.phase = "Active"
                                 /\ directory.h = intent

\* Reachability controls intentionally negate desired states. TLC must return
\* an invariant counterexample for each, rather than a vacuous safety pass.
NoSuccessfulHandoff == TargetGrant \notin writers
NoRecoveredHandoff == ~(TargetGrant \in writers /\ recoveredFreeze)
NoRecoveredActivation == ~(TargetGrant \in writers /\ lostActivationReply)
NoLateRejection == ~(TargetGrant \in writers /\
                    \E x \in Executors : requests[x] = "Rejected")
NoStaleRouteRejection == ~routeRejected
NoAbortRetry == lastId < 2
=============================================================================
