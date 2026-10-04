# Remote compilation and retained outcomes

Remote compilation keeps the source preparation, compiler process and compiled
artifact beside the registered executor workspace. The session owner retains
approval and budget authority. A compiler result names an executor-owned
artifact, so the owner never interprets its location as a local filesystem path.

The components described here implement the storage and validation boundaries in
[protocol 067](../../protocol-change/067-remote-workspace-services.md). The live
Compile service, its command routing and the shipped remote deployment still
require assembly. The sequence below specifies that assembly's required order;
it does not claim that a separate-host workflow has passed acceptance.

## Three records describe different work

The owner journal retains the original tool, physical service and cleared native
command. Its service key includes the parent tool identity, complete workspace
scope, physical operation and step, service UUID, and input and enrollment
digests. The command reference retains that full service key. An operation number
alone cannot distinguish two physical services under different parents.

The executor resource journal retains the original Compile input, preparation
state and outer completion. Its separate native journal retains the exact
compiler request, admission, ordered output and terminal evidence. Those records
answer different questions: preparing files does not establish native admission,
and a compiler exit does not establish a finalized artifact.

| Record | What its commit establishes |
|---|---|
| Owner command reservation | The original native UUID and exact cleared request are retained before transmission. |
| Resource Ready | The recorded allocation and preparation receipt belong to the original service. |
| Native Admit | The native journal has admitted the exact compiler request. |
| Resource association | The retained native request matches this service's full identity and compiler template. |
| Native terminal commit | The native reducer has accepted the retained terminal payload as evidence. |
| Resource completion | Exact outer result bytes and their digest can be recovered without finalizing again. |

The [custody guide](remote-custody.md) explains owner reservations and tool-result
recovery. `executor/remote/resource_journal` owns the executor records above.
Its named SQL queries are compiled by Parrot/sqlc; schema installation and
transaction control remain explicit in the actor.

## Preparation grants one live continuation

The resource journal reserves room for the input, preparation receipt, native
association and completion before returning a preparation claim. That opaque
claim belongs to the original journal endpoint and original input. A reopened
journal can inspect the row, but cannot recover the claim from it.

The physical service must exclusively create the allocation, prepare fixed
sources and the offline seed, and then commit Ready. An existing allocation is a
collision; it cannot be reused or deleted to make a retry work. The shared
compiler helpers perform preparation and finalization, while the live service
must enforce this ordering and the original deadline.

```mermaid
sequenceDiagram
    participant Owner as Session owner
    participant Resource as Executor resource journal
    participant Compile as Live Compile continuation
    participant Native as Native journal and executor
    Owner->>Resource: Retain original input and reserve outcome capacity
    Resource-->>Compile: Original preparation claim
    Compile->>Compile: Prepare exclusive allocation and offline sources
    Compile->>Resource: Commit Ready
    Compile-->>Owner: Offer exact compiler command
    Owner->>Owner: Clear and retain original native request
    Owner->>Native: Submit exact cleared request
    Native->>Native: Retain request and authority, commit Admit
    Native->>Resource: Commit live association under the original claim
    Resource-->>Native: Exact launch permit, or refusal
    Native->>Native: Commit launch intent, then start compiler
    Native->>Native: Retain output and commit terminal evidence
    Native-->>Compile: Exact committed native result
    Compile->>Compile: Finalize and fingerprint artifact once
    Compile->>Resource: Commit exact outer completion
    Resource-->>Owner: Retained completion bytes
    Owner->>Owner: Commit receipt before acknowledgement
```

The resource journal now implements that live association boundary. Native service
assembly must call it between native admission and launch intent. The historical
association API remains available for reconciliation, but returns no launch permit.

### Cancellation and admission share one transaction order

`associate_live_native` requires the original preparation claim. It first reads
the exact native request, finite authority and committed admission. Those reads
occur outside the resource writer transaction so one actor does not hold a writer
lock while asking another actor for evidence.

The final resource transaction checks the full original input again. The scope
must still be open, preparation must be Ready, and the native association must be
absent. It commits the association before returning an opaque permit bound to the
exact resource endpoint, command reference, native key and request digest.

If cancellation commits first, the association refuses. If association commits
first, cancellation follows the retained native key. The latter ordering can race
process startup; it does not establish that no process ran. The native reducer's
separate launch-intent transition still permits at most one launch.

The permit carries no renewed deadline. The original native continuation must
check elapsed time before launch. Duplicate association, a lost reply or journal
recovery cannot return another permit. Gleam values are copyable, so trusted
assembly must keep the returned permit in that original continuation.

`retained_input` recovers the original bounded data through its complete service
key, including after cancellation, scope sealing or native endpoint loss. It never
reconstructs a preparation claim. This lets recovery compare history while keeping
fresh execution permission unavailable.

## Failure preserves what can be proved

A failure during preparation can produce a Before-native completion only while
the original claim still names live Preparing state. The completion transaction
also fences a late Ready commit. After Ready exists, absence of a native
association proves only that the association is absent. A native submission may
already be in flight, so the result must remain uncertain.

A completion after native work requires both retained terminal bytes and the
matching committed native evidence. Retaining the bytes can precede the reducer
commit. Treating those bytes alone as completion would incorrectly close that
window. The live continuation must then finalize the artifact once and retain the
closed outer result before advertising it.

Exact historical association, completion and acknowledgement retries read the
resource journal first. They remain available after loss of the native endpoint,
resource release or scope closure. They do not renew a deadline, re-clear a
command or repeat source preparation. Conflicting bytes fail instead of replacing
the original record.

## Receipts and cleanup are independent

The outer Compile receipt means that the owner retained the exact Compile result.
The native receipt means that the owner retained the compiler's exact native
result. Native retirement requires a separate witness that the scoped native
processes have drained. Resource cleanup records what happened to the allocation.
No one of these facts substitutes for the others.

The resource database uses format 2 and reserves future result capacity before
effects. It refuses an older format before querying new columns. Header queries
check scalar types, lengths and reserved capacity before transferring bodies;
body queries retain their own guards. These checks bound what a corrupt row can
materialize as well as what a valid request can reserve.

## Verification and integration boundary

The [custody review](../review/distributed-compile-outcome-custody.md) records real
SQLite tests, native admission and terminal evidence, independent review findings
and targeted mutations. The [P model review](../review/distributed-compile-custody-model.md)
records bounded checks of preparation, settlement and receipt ordering. Those
model checks do not establish database crash atomicity or operating-system
behavior.

The [live-admission review](../review/distributed-live-compile-admission.md)
records the resource transaction controls, complete-identity mutations and
independent executor gate. These checks precede the native service wiring shown
in the sequence above.

Production acceptance still requires the live Compile/Launch services, exact
command routing, executor registration and ordinary tool consumers. The final
test must run the owner and executor on separate hosts with the workspace absent
from the owner's disk, including cancellation, restart and lost replies.
