# Exact product command and outcome custody

ProductSystem is an additive composition over the unchanged native Owner,
Executor and Helper. ProductOwner persists outer service requests before send,
retains exact cleared offers, allocates native Prepared identities and retains
outer completions before their receipts. ProductExecutor owns two outer rows,
resource intent, the one live resource claim and issued lease evidence.
ProductScenario drives native work and forwards actual Owner views. It cannot
emit native admission, start, terminal, receipt or retirement facts.

The model has one ToolKey equality class, Compile and Launch outer IDs 1 and 2,
CompileCommand and SatelliteCommand command refs 1 and 2, two content/binding
classes, and current/mismatched scope classes. Registration and command digest
are separate offer fields. Service request, command and result digests remain
separate. Scope, artifact, original compile request and resources digest are
retained in the Launch intent. These classes abstract bounded exact bytes;
they do not prove serialization, hash collision resistance or shell semantics.

Child addresses are tuples `(tag, name, ordinal, purpose, role, namespace)`.
Tag 1 denotes fixed native roles; 2 is an admitted capability tuple; 3 is the
legacy Capability address. Names 1 and 2 represent fs.read and proc.run. Both
use ordinal zero. Purposes 1 and 2 represent SemanticWorkspace and NativeCommand.
The namespace distinguishes the separate capacity-one owner subcase. The model
compares the logical tuple independently with its constructed address before
reservation, so an alias is detected even if the second request conflicts.
The compile/launch path uses two distinct fixed child roles; the capability
case reserves four addresses and checks capacity-one refusal separately.
The production parent ceiling is 64; this is not a proof for arbitrary bounds.

A cleared offer is committed before a separate submission turn. Prepared
custody then precedes the existing native Owner's possible send. Recovery
queries that original identity without minting a replacement. Actual Helper
start is required before the launch-loss scenario loses its observation.
The lost observation remains unknown, and cleanup is attempted while the
Helper still retains custody. A resource release cannot create retirement.

Resource intent commits before creation. A crash after creation revokes the
original live claim, leaving ResourceUnknown. Recovery cannot create again.
A separate scenario persists the issued lease before losing its reply and
queries that exact lease under the original Launch service. ProductOwner
retains the typed resource observation alongside that original request, and
validates the lease before clearing SatelliteCommand. A mismatched
scope/artifact candidate reaches the shared lease acceptance decision before
it is refused. Both resource scenarios first perform native compilation.

Native Owner terminal storage precedes ProductExecutor completion. ProductOwner
then stores the exact typed outer result before ProductExecutor accepts its
receipt. The native model uses the request digest as its terminal witness;
that field is not relabeled as proof of actual terminal bytes. A live final
ToolOutcome has its own retained equality class. Child-only recovery omits
that final store and remains unknown even with both native receipts and outer
completions intact. No program replay reconstructs the final report.

## Histories and cases

ProductSafety retains clearance, native reservation, resource claim revocation,
created resources, exact completions, owner storage, final outcome and actual
native retirement independently. All four original native safety monitors
remain active in every product normal case and positive probe. Reliable cases
also check DirectedProgress. ProductFaults has no liveness obligation.

| Normal case | Checked transition and positive control |
| --- | --- |
| tcProductLifecycle | Compile and satellite use actual native actors and separate outer receipts; completion and cleared-before-admission probes. |
| tcProductOfferConflict | Changed command replay and mismatched lease candidate are refused; original native identities remain. |
| tcProductResourceUnknown | Create, crash/revoke before issue, then query original Launch identity; created+revoked history establishes the probe. |
| tcProductLeaseRecovery | Durable issue, reply loss and original-service lease readback. |
| tcProductLaunchLoss | Actual satellite start, lost observation, same-ID query and cleanup before retirement; native start history establishes the probe. |
| tcProductChildAddresses | Equal ordinals, distinct capability names/purposes, legacy tag and capacity-one refusal. |
| tcProductChildOnlyRecovery | Two native receipts and outer results survive while the final store remains absent; independent histories establish the probe. |
| tcProductFaults | Reliable Compile bootstrap, then twelve finite Launch fault actions: exact retry/query/replay, duplicate offer/result drops, owner/executor crash, release, cancellation and retirement. The mixed probe requires independent resource intent/create/lease and actual start histories before cleanup of the same still-unretired native key. |

Every product mutation changes one real decision in a new PSrc file. The
unmodified selected scenario must pass first; the mutant must compile and
fail exactly its intended assertion. Neither the native nor product monitor
source is changed in a mutation.

| Mutation | Target assertion |
| --- | --- |
| product-change-cleared-offer | native command differed from owner-cleared offer |
| product-remint-uncertain | uncertain command allocated replacement identity |
| product-cap-name-alias | distinct product children shared an address |
| product-recreate-resource | resource created without original live claim |
| product-foreign-lease | issued resource did not match admitted artifact |
| product-loss-as-refusal | possible native launch reported never launched |
| product-early-outer-receipt | outer receipt preceded exact owner completion |
| product-final-from-children | child evidence fabricated final tool outcome |
| product-cleanup-as-retirement | resource cleanup fabricated native retirement |

## Bounds and production obligations

Outer and native stores each retain at most two rows. The native helper keeps
one active execution and two pending cancels. The reliable product workload
creates at most two native commands; the fault scenario performs twelve actions
after actual Launch start. Compile completion is reliable so the fault loop cannot
prevent Launch admission. Retry, native/resource queries and replay address the
original Launch identities. Pre-issue resource revocation remains the isolated
ResourceUnknown scenario: resource creation and lease issue occupy one handler,
so the mixed scheduler does not claim a crash between those operations. Receipt and native retirement requests are sent
once per execution, so their reply views cannot form a feedback producer.

A conservative communication bound is 512 messages: reserve 128 for bootstrap
and the two fixed native/outer completion chains, plus at most 32 messages
from each of twelve fault actions. Retry/reconciliation replies cannot launch
new work; duplicate product replies cannot resubmit an already cleared command.
The only repeated driver producer is the twelve-turn eTick loop. P mailboxes
are bounded by this finite workload, not by a production backpressure model.
The checker still uses 1,000 steps, 60 seconds and fail-on-maxsteps. Runs are
schedule-based bug finding, not exhaustive exploration or parameterized proof.

| Model event or decision | Required production boundary and regression |
| --- | --- |
| mProductCustody / mProductAdmission | Original ServiceKey reservation before possible send/admission; crash/readback with exact retained content. |
| mProductCleared / mProductNativeReserved | Owner-cleared exact command, mapping and ChildOrigin in durable Prepared; altered offer and unchanged deadline regressions. |
| mProductChildCandidate | Canonical capability name/ordinal/purpose and fixed-role child encoding; legacy compatibility and parent-capacity tests. |
| Resource intent/create/revocation / mProductLease | Single live claim, exact artifact/scope/resource lease; actual create-before-reply-loss and issue-before-reply-loss injection. |
| Native mStart / product launch observation | Typed refusal versus unknown after actual helper start; single-shot and persistent launch hosts. |
| Native mOwnerStored / product completion/store/receipt | Independent native and outer exact payload commit/readback; skipped owner receipt mutation. |
| mProductFinalStored / recovery | Exact final ToolOutcome retained separately; child-only restart remains unknown without program replay. |
| Native mRetired / cleanup observation | Actual native descendant retirement independent from resource or channel release; cleanup-before-retirement regression. |

The table names outstanding bridge obligations, not implemented source paths.
Authentication, codec correctness, clock arithmetic, durable-store mechanics,
physical memory/disk ceilings and shipped two-host behavior remain separate.
Native pre-intent refusal/GC semantics are intentionally not broadened here;
the original P model's missing pre-launch refusal transition remains covered
by the existing Gleam reducer tests rather than this composition.


## Final-source verification

On 2026-10-04 the strict full runner exited zero for all 36 cases: fourteen
normal cases each passed 1,000 schedules, and twenty-two probes reported their
exact intended assertions. Every product probe reached its witness on schedule
1. The mutation runner exited zero for all fourteen controls: each unmodified
case passed 100 schedules, and each compiled mutant failed its intended
assertion on schedule 1. P version 3.0.4.0 used seed 697 and the unchanged
1,000-step/60-second checker bounds.

Evidence: `PCheckerOutput/gate-20261004T151525139467/results.json` and
`PCheckerOutput/mutations-20261004T151525138668/results.json`, with adjacent
source-hashes.json manifests and immutable source snapshots. These are local
model gates. Fresh independent review and production acceptance remain separate.

The independent review found that the earlier mixed driver entered its fault
loop during Compile and never admitted Launch. The repaired probe requires
actual service-2 resource intent, creation and issue, actual Helper start for
native key 2, then a cleanup observation for that same key without prior native
retirement evidence. It reached this history on schedule 1. Driver stage alone
cannot establish the witness. The earlier 35-case run remains valid for its
source but did not establish Launch/resource mixed-fault reachability.
