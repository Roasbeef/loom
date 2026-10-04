# Distributed ownership and planned handoff

D1 for Loom #697, against source baseline
`ae1a319a48aa3feed92f5f65efd09034df635675`. This is first-wave protocol
evidence, not a production authority service or an end-to-end proof of Loom.
The contract comes from the reviewed
[distributed runtime note](../../../docs/design-notes/distributed-runtime.md)
and [API plan](../../../docs/design-notes/distributed-runtime-api.md).

`Ownership.tla` contains the actual PlusCal handoff algorithm and its generated
TLA+ translation. `Metadata.tla` expands the conditional metadata boundary into
submission, durable settlement and caller observation, as described below. `run.py` checks the translation against the pinned translator,
then exhaustively explores the finite safety model and requires the named
reachability and mutation counterexamples. No root scripts, build targets,
Gleam modules, or global configuration are changed by this runner.

## Run it

From the repository root:

```sh
python3 protocol/models/distributed-authority/run.py
python3 protocol/models/distributed-authority/run.py --case MutantAdmission
python3 protocol/models/distributed-authority/run.py --translate
```

The full runner exits **0** only when safety passes and all nine ownership controls and fourteen metadata controls produce their
intended witnesses. Both metadata capacity bounds must exhaust safely. A control requires TLC exit **12**, the
exact named invariant, a state count, and a multi-state trace. A parse error,
wrong invariant, unavailable tool, or timeout fails the runner with exit **1**.
`--translate` updates only the generated sections of both models and does
not run TLC. Ordinary checking regenerates into an isolated directory and
fails on any byte difference after trimming the translator's trailing
whitespace, without editing the checked-in model.

Requirements: Python 3.9+, `curl` for first provisioning, and Java 8+.
The default is `/usr/bin/java`; `--java /path/to/java` selects another existing
runtime. The official [TLA tools v1.7.1 release](https://github.com/tlaplus/tlaplus/releases/tag/v1.7.1)
jar is downloaded into ignored `.cache/`, checked on every run, and never
vendored. Its SHA-256 is:

```text
d532ba31aafe17afba1130f92410d9257454ff7393d1eb2fe032f0c07f352da5
```

Each invocation writes isolated logs and a `summary.json` under ignored
`.runs/<run-id>/`. The summary retains the exact argument arrays, exits,
counts, model/configuration hashes, and log paths. Full TLC logs contain
counterexamples with every variable and the generated TLA action location.
[Witnesses](WITNESSES.md) records compact mutation traces from the checked run.

The TLC command inside each case directory is:

```sh
/usr/bin/java -Xmx512m -XX:MaxDirectMemorySize=64m \
  -cp <absolute-model-directory>/.cache/tla2tools-1.7.1.jar \
  tlc2.TLC -workers 1 -seed 1 -fp 0 \
  -metadir <absolute-case-directory>/states \
  -config <case>.cfg Ownership.tla
```

The runner bounds each TLC process to **60 seconds**, a **512 MiB heap**,
**64 MiB direct memory**, and **one worker**. Twenty-six sequential cases give a 1560-second TLC budget, plus two
30-second translations and an optional 60-second download. JVM native memory and retained log/state disk space are not capped
by those JVM flags. `--timeout N` accepts 1..120 seconds; exceeding that budget
is a failure, never a partial success. TLC performs complete breadth-first
checking, not simulation or a depth-pruned search. Fingerprints are finite:
TLC's collision estimates remain a limit of the evidence.

On the supplied machine `/usr/bin/java` is Java 8u152. An initial v1.8.0 jar
failed with `UnsupportedClassVersionError` (class version 55, runtime maximum
52); v1.7.1 translated and checked successfully. The sandbox's first download
failed with `curl: (6) Could not resolve host: github.com`. Provisioning
succeeded with execution permission. TLC inside that sandbox failed with
`java.rmi.server.ExportException: Port already in use: 0`, caused by
`java.net.BindException: Operation not permitted (Bind failed)`. Actual TLC
checks ran with permission outside that sandbox. The runner never retries
such a denial by silently weakening isolation.

## State and ordering

The planned transfer is:

```text
Active(A,1) -> Draining(A,1,h,B) -> Frozen(h,1,B,consistent cut)
            -> Prepared(h,2,B,target-verified cut) -> Active(B,2)
```

The model retains A in the directory's owner/epoch fields until Prepared;
B is the fixed destination. Prepared names B/2 but grants no writer until
Active. The source validates a consistent cut before Frozen publication;
B independently verifies its identity, digest, and artifacts before Prepared.
Neither publication nor verification is modeled as copying a live `.db` file.

| State or step | Ownership obligation |
| --- | --- |
| Durable `intent`, then Draining commit | Reserve a non-reused handoff ID before transmission; reconcile an unknown reply by that ID. Draining stops new source requests. |
| `seal = Cancelled`, then abort commit | Serialize local cancellation against freeze. Absence of a directory freeze alone cannot authorize resumption. Reconcile the abort receipt before allocating another ID. |
| `seal = Frozen`, then cut formation | Close A's local writer and permanently prevent reopening epoch 1. A crash here leaves the directory Draining while local custody is already frozen. |
| Frozen publication | Publish the actual local freeze and source-validated consistent cut. Publication can remain absent or its reply can remain unknown. |
| `targetIntent`, target verification | Journal the same handoff at B; verify the cut independently of directory publication. |
| Executor closure, retirement acknowledgement | Persistently reject epoch-1 admission and await native retirement. Requests can remain Pending in transport after acknowledgement. |
| Prepared and Active commits | Require both executors' receipts and target verification; commit epoch 2. B reconciles lost replies before opening its writer. |
| Crash and restart | Clear volatile observations and local writer handles. Retain seals, journals, executor fences, acknowledgements, and native work. Reopening requires fresh authority read-back. |
| Cached route and partition | A route remains A until refreshed, but it constructs no grant. Isolation changes communication only; it never activates B or retires native work. |

The safety invariants count physical writer grants across **all modeled
epochs**, and count old native mutation authority even when its executor is
down or disconnected. One owner *per epoch* is insufficient. `Safety.cfg`
checks type closure, writer exclusivity, native/writer exclusivity, permanent
old-epoch closure, truthful freeze publication, activation evidence, sound
executor acknowledgements, stable handoff identity, and writer authority.
`Ownership.cfg` carries the same checks for a direct default TLC invocation.

## Bounds, fairness, and controls

The model has one session, source A, destination B, two relevant executors,
epochs 1 and 2, and at most two unique handoff IDs. Both executors are required;
there is no optional executor hidden by a one-acknowledgement shortcut.
Each executor has one source request slot, with states Unsent, Pending,
Running, Retired, or Rejected. Sending and delivery are separate steps.
Repeated control delivery/read-back is idempotent; duplicate execution
requests, queues with multiple entries, results, and cancellation identities
belong to D2's P model.

Any subset of the four actors can be crashed. Crashes and restarts may repeat
without a numeric bound because they cycle within the finite graph. Native
work survives an executor crash until the modeled retirement event.
The network can isolate one actor at a time, or make the directory unavailable
to everyone. This covers source, target, executor, and metadata unavailability,
but not every simultaneous partition topology. Delay and partition duration
are unbounded through stuttering and repeated environment steps.

`Spec` has **no weak or strong fairness assumptions**. `CHECK_DEADLOCK FALSE`
permits safe blocking; no universal liveness or automatic takeover is claimed.
Reachability controls negate desired states and require TLC to find them
while every safety invariant still holds. Those existential witnesses do not
prove that an arbitrary stalled handoff eventually completes. Eventual
completion would additionally require communication, metadata availability,
scheduling, durable capacity, and native cleanup.

| Configuration | Required witness or result | TLC exit |
| --- | --- | --- |
| `Safety` | Exhaust the finite graph with every safety invariant intact. | 0 |
| `ReachHandoff` | B opens its epoch-2 writer. | 12 |
| `ReachRecovery` | A freezes, crashes before freeze publication, restarts, and the same handoff completes on B. | 12 |
| `ReachActivationReply` | B's activation commits, its observation is lost at a crash, and read-back of the same ID permits B to open. | 12 |
| `ReachDelayed` | A request delayed through handoff is rejected after B opens. | 12 |
| `ReachStaleRoute` | Ingress following the stale A route is refused. | 12 |
| `ReachAbortRetry` | A cancels before freeze, reconciles that receipt, and allocates ID 2. | 12 |
| `MutantDirectory` | Publish Frozen and fabricate a cut while A's writer remains open; `OneEffectiveWriter` fails across epochs. | 12 |
| `MutantAdmission` | Ignore the executor's durable closure when admitting a delayed request; `NoOverlappingAuthority` fails. | 12 |
| `MutantCut` | Prepare without B verifying the cut; `ActivationHasEvidence` fails when Active commits. | 12 |

Mutations select one named defective transition in the same translated
algorithm. Their configurations retain `TypeOK` and focus on the intended
invariant, so earlier symptoms cannot substitute for the requested failure.
All intended mutant invariants are also checked in the unmutated Safety run.

## Implementation bridge and gaps

These are protocol obligations, not claims that corresponding distributed
production functions exist at the pinned baseline. The source seal and
consistent cut would cross existing storage/writer and session restart
boundaries; the local SQLite lease alone is not a cluster fence.

| Model boundary | Required implementation mapping | Deliberate gap |
| --- | --- | --- |
| Serialized directory replacement | Future C1 authority reducer and conditional metadata adapter under protocol-change/066. | The Metadata model checks abstract ABA and receipt-retention obligations; no Khepri/Ra algorithm, quorum implementation or transaction FFI is proved. |
| Local freeze/cancel seal | Durable session writer admission and restart checks near `packages/storage` and `packages/runtime`. | Atomic local persistence, writer closure ordering, disk corruption, and competing local handles are assumed. |
| Consistent cut and target verification | Future M1 backup/manifest/transfer/verification boundary. | No SQLite WAL, byte transfer, digest collision, artifact enumeration, or decoder implementation is modeled. |
| Executor epoch closure and retirement | D2 P model, then future durable executor ledger and admission path in `packages/executor`. | The relevant executor set is fixed and complete. No enrollment race, workspace movement, native helper implementation, receipt GC, or authenticated wire is proved. |
| Startup, journals, unknown commits | Future authority/read-back wiring at daemon/session activation. | Replies are separate observations, not explicit packet queues. Metadata commits and source-local journal writes are atomic abstract steps. |
| Routing | Future C2 ingress resolves a hint, then checks actual authority. | Refusal is an abstract event; authentication, membership, transport, and production routing are outside this model. |

Epoch 2 represents B's new mutation authority through its writer grant;
new B execution requests are not expanded. The model checks A-to-B only,
not a B-to-A return, general workspace ownership, multiple sessions, malicious
participants, disk loss, or automatic recovery of a dead source. The local
seal orders cancellation with freeze; the model assumes the implementation
can durably establish that order. It does not assume a read of two unrelated
stores supplies an atomic abort decision.

Integration must map each modeled durability boundary to real source paths
and failure-injection tests, replay the mutation shapes through those tests,
and keep that mapping pinned as code changes. No Lean-to-Gleam extraction or
differential bridge exists here. A checked abstract transition graph is not
an end-to-end proof of the authority implementation or the deployed runtime.


## Conditional metadata after an ambiguous deadline

The metadata compatibility spike observed a transaction return a timeout and
later become visible with its retained receipt. `Metadata.tla` models that
schedule without adopting Khepri or depending on its API. An accepted command
can remain pending, settle atomically with its final receipt, and lose or delay
its reply. A deadline only changes the caller's view to `Unknown`. An absent
receipt before settlement also leaves that view unknown.

The original request reserves capacity before transmission and retains its
operation ID, digest and complete expected authority envelope. An exact retry
uses those same fields. Receipt lookup precedes conditional mutation, so an
already settled operation returns its stored outcome without another transition.
An ID with a conflicting digest cannot overwrite the original reservation or
receipt. Both successful and conditionally rejected outcomes remain retained.
There is no receipt eviction to admit a new operation.

The complete predicate compares incarnation, revision, ownership epoch and
owner. Administrative recreation advances incarnation and both numeric fences;
receipts remain valid historical results. A receipt does not construct an
owner grant. `Ownership.tla` continues to check local freeze, target evidence,
executor retirement and physical writer exclusivity separately.

| Safety predicate | Obligation |
| --- | --- |
| `CapacityReserved` | Submitted identities already own one of the bounded retained receipt slots. |
| `ReceiptRetained` | Every settled ID retains exactly its original digest, result and authority value through compaction. |
| `StableOperationId` | Retrying one unresolved logical operation preserves its ID, digest and predicate. |
| `OneLogicalCommit` | That logical operation changes authority at most once. |
| `NoFalseNoCommit` | A timeout cannot assert non-commit while its receipt records success. |
| `NoMinorityAck` | Every delivered success/rejection has actually settled and has a matching durable receipt. |
| `MonotonicFence`, `NoReusedIncarnation` | Epoch/revision cannot fall below retained history; recreation cannot reuse the old incarnation. |
| `ResultHasReceipt` | A caller's resolved outcome matches the stored outcome for its operation. |

`NoMinorityAck` rejects a fabricated successful minority reply for an unsettled
command. It permits delivery of a previously quorum-settled receipt after the
caller becomes isolated. The distinction matters: a historical receipt can
resolve uncertainty, but cannot establish current mutation authority.

The bounds are one store/key, two operation IDs, three submitted envelopes
(original, one retry, and either a stale contender or digest conflict), two
digest equality classes, one recreation, epochs/revisions 1 through 4, and
receipt capacity 1 or 2. Both capacities receive exhaustive safety checks.
`Majority`, `Minority` and `Offline` represent access to one serialized store,
not a Raft implementation or three explicit replica logs. Settlement requires
quorum access; a minority submission can remain pending until healing. Delay
is unbounded through stuttering. `Spec` has no fairness assumptions, and safe
blocking or permanently unknown outcomes remain valid.

Nine positive controls require unknown commit, missing receipt followed by
commit, reconciliation after a lost success reply, a late reply, post-recreation
stale rejection, conflicting digest, capacity refusal, minority submission
followed by timeout/healing/commit, and reconciliation after compaction. Five
mutants require the exact forbidden schedule: a timeout classified as no
commit; a retry allocated a new ID with a refreshed predicate, committing the
same logical transition twice; a success fabricated without quorum settlement;
an ABA reset of the complete authority envelope; and receipt deletion during
compaction. [Witnesses](WITNESSES.md) records the checked counts and traces.

This expands an abstract metadata boundary. It is not a proved refinement
relation to the handoff algorithm, a metadata reducer proof, or a compiled
Gleam/store implementation bridge. Reservation, atomic receipt+authority
settlement, authoritative reconciliation, digest binding and durable fences
are implementation obligations. Disk failure, replica membership changes,
Byzantine inputs, schema upgrades, actual snapshots, byte/disk budgets and
receipt retention horizons are outside this bounded model. Compaction is only
a projection that must retain the modeled facts. No automatic failover or
unconditional progress is claimed. The existing Lean/Gleam admission bridge
checks a different reducer and does not close these metadata gaps.
