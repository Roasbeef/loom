# 066: Distributed authority and execution foundations

Status: **implementation proposal** for issue
[#697](https://github.com/Roasbeef/loom/issues/697). The owner authorized the
development wave on 2026-10-04 after the design review. This proposal records
the first pure implementation and executable models; it does not enable a
remote listener, change the shipped helper wire, or grant cluster membership.

Baseline: `ae1a319a48aa3feed92f5f65efd09034df635675`. The reviewed
[architecture](../docs/design-notes/distributed-runtime.md) and
[delivery plan](../docs/design-notes/distributed-runtime-api.md) explain the
deployment choices and the later integration slices.

## Problem

The local dispatcher can distinguish failure to start from an execution it
owns. A remote dispatcher cannot infer that distinction from a timeout: its
request may have started a process before the reply was lost. Retrying the
command as a new execution can repeat a filesystem mutation or external effect.

Session movement has a related uncertainty. Copying a SQLite file does not
disable the original writer or stop native processes using its workspace.
Giving B a new generation while A still runs would satisfy one-owner-per-
generation and still produce two effective writers.

The first development wave establishes those two contracts before adding
network effects. It supplies a bounded pure admission reducer and executable
models. The durable store, native adapter and transport must later preserve
the ordering those artifacts specify.

## Existing interfaces and compatibility

Spec Part 1.4 and the native helper protocol remain unchanged in this wave.
`broker/dispatch.StartRefusal` still means nothing is running or held. The
local `broker/executor` remains the production dispatcher. Its diagnostic
inventory does not become a durable remote ledger by implication.

The added executor modules are internal groundwork for the remote adapter.
They must not be advertised in the model's capability surface as a usable
remote execution API. Later wire, workspace and capability-forwarding
proposals must specify their serialization and authorization boundaries.

## Normative execution rules

### Identity and admission

An execution identity MUST bind its session, operation, executor and workspace
authority. Request content MUST be bound by an exact digest. Connection IDs
and boot incarnations MUST NOT replace the logical execution identity.
Typed constructors MUST reject malformed and oversized external values.
Opaque IDs do not assert global uniqueness; the host must allocate them from
the authorized identity source and persist them before submission.

The executor MUST serialize admission against the current authority scope and
reserve bounded durable capacity before accepting a new execution. An exact
duplicate returns the same logical execution's evidence without emitting
another launch. Reusing an identity with a different digest MUST conflict.
New identities under a closed or stale admission epoch MUST be rejected.

Closing an epoch stops new admission. It MUST NOT erase the evidence needed
to reconcile already admitted executions. A subsequent connection may query
old execution evidence under current authentication without reviving the old
connection's mutation authority.

An admitted request whose launch intent has never committed MUST have a
definite refusal path. Closing admission must not leave that request unable
to launch and unable to settle. Refusal before launch records a terminal
outcome with native retirement already established by the absence of any
launch authorization. It still requires the owner's durable receipt before
collection. That transition MUST be rejected once launch intent exists.

### Persistence and launch

The pure reducer describes a state transition; it does not write a journal or
perform an effect. Its host MUST serialize transitions and persist the next
state before exposing admission acknowledgement or performing the authorized
native launch. A successful persistence acknowledgement is the ordering point.

The host MUST persist launch intent before native start. After a crash in
that interval, recovery MUST represent that launch may have happened. It
MUST NOT emit a second launch solely because it lacks a native-start reply.
Later native reconciliation may establish more evidence; a missing process
alone is not proof that a command never ran.

An opaque transition result is not a linear token. Duplicating a Gleam value
does not authorize applying its native effect twice. The host adapter owns
exactly-once application within one live serialized transition and conservative
recovery after a crash. Implementation tests must cover that adapter before
the remote runtime is declared usable.

### Outcomes, retirement and collection

Terminal outcome, native retirement and durable owner receipt MUST remain
separate facts. A terminal result does not prove descendant cleanup. A
disconnection, timeout or dead BEAM monitor does not supply native retirement.
The owner MUST acknowledge receipt only after its own durable record commits.

Evidence may be collected only after its required receipt and native retirement
are established. Collection MUST leave a durable replay fence: forgetting a
row must never make its identity eligible for a second execution. The initial
reducer may retain bounded per-epoch records until the entire epoch closes,
then retain an epoch high-water fence. Such retention trades capacity for a
smaller safe state machine and is preferable to unsafe per-row eviction.

The host MUST refuse new work when it cannot reserve evidence capacity. No
contract simultaneously promises bounded storage, unlimited admission and
lossless results through indefinitely long disconnection.

## Normative authority rules

A session MUST have at most one effective writer and mutation authority across
all epochs. An epoch identifies authority; it does not by itself stop an old
writer. Cached directory entries and presence MUST NOT grant authority.

Planned handoff follows an atomic directory transition through active,
draining, frozen, prepared and active-at-target phases. Each phase carries
its own required evidence. The source MUST stop new admission, settle or
record existing outcomes, and durably disable its old writer before source
freeze is acknowledged.

Each relevant executor MUST close the source admission epoch, drain accepted
requests and account for native custody before target activation. Delayed
requests under that source epoch must remain refused after the fence. A
partition prevents acknowledgement and therefore blocks handoff; it does not
permit takeover.

The target MUST verify a consistent durable cut, including required artifacts,
before preparation. Only the committed activation transition authorizes the
target writer and effect admission. Routing publication follows that authority
decision. A lost reply is reconciled by the existing handoff identity.

Before source freeze, abort may resume the source only after confirming that
freeze did not occur. After freeze, the old epoch is never reopened. Returning
to the original machine uses a verified cut and a fresh epoch. After target
writes, returning uses the target's newer state, never the old source copy.

## Alternatives and costs

Treating transport failure as refusal was rejected because a lost reply cannot
prove non-execution. Automatic replay remains available only to a later policy
that establishes a specific operation's replay safety.

Using a process registry as ownership authority was rejected because process
discovery does not serialize durable ownership transitions. Khepri or direct
Ra remains a later metadata decision, subject to a compatibility spike. The
single-orchestrator remote-executor slice does not require either dependency.

Sharing the workspace through a general distributed filesystem was deferred.
The first remote adapter must route all workspace operations to the registered
executor. Ordinary tools, code mode and language servers must observe that
same checkout before Phase 1 meets its exit criteria.

The cost of conservative recovery is explicit unknown outcomes and blocked
handoffs. The cost of bounded evidence retention is admission refusal under
pressure. Both outcomes preserve the operator's ability to investigate without
silently duplicating a mutation or losing cleanup custody.

## Verification contract

The PlusCal model checks planned ownership transfer against an abstract atomic
directory. The P model checks remote execution ordering and uncertainty under
bounded message schedules. Both MUST demonstrate reachable successful paths
and rejected mutations, with bounds and omitted mechanisms stated in their
READMEs. Pure reducer regressions MUST execute the actual Gleam functions.

Models MUST distinguish persisted state from volatile observations. A model
that treats native launch and journal commit as one indivisible transition
cannot justify recovery across that boundary. Model-to-code mappings identify
implemented functions separately from future adapters and protocol obligations.

Lean is reserved for a small settled pure invariant with a maintained bridge
to the production reducer. No proof of a separately written transition system
will be presented as proof of the running distributed harness.

This first wave passes only when the implemented reducer tests and both model
runners pass, their mutation controls fail as intended, and independent review
has been dispositioned. That result does not complete #697: durable storage,
authenticated transport, remote filesystem operations and the real-host
integration gates remain subsequent work.
