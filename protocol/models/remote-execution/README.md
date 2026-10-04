# Remote execution custody model (D2, #697)

This runnable P model checks the remote execution foundation proposed for
Loom at `ae1a319a48aa3feed92f5f65efd09034df635675`. We separate admission,
launch intent, terminal outcome, native retirement and owner receipt because
none of those facts substitutes for another. A lost connection leaves the
execution's evidence intact; a crash after launch intent never grants another
launch permission.

The contract comes from the [distributed runtime note](../../../docs/design-notes/distributed-runtime.md)
and [API plan](../../../docs/design-notes/distributed-runtime-api.md).
[Protocol 066](../../../protocol-change/066-distributed-runtime-foundations.md)
records the host obligations. This model does not implement remote execution,
persistence or networking, and passing it is not a proof of
the production executor or an equivalence proof for the pure reducer.

## Run it

Use the installed P tool and Python 3. The local runner searches `PATH`, then
`~/.dotnet/tools/p`; `P_BIN` overrides that selection. It installs nothing.
The tool's `compile --help` and `check --help` were inspected before choosing
the options below.

From the repository root:

```sh
bash protocol/models/remote-execution/check.sh
```

The gate compiles a source snapshot, checks every declared normal case,
requires every `tcProbe*` to produce its exact intended assertion, and checks
all five mutations. It exits zero only if every check succeeds. Compiler
errors, timeout, memory exhaustion, max-step exhaustion, unrelated assertions,
missing test cases and probes without witnesses fail the gate. Safety cases
must explore the entire requested schedule count. Each invocation has separate
build artifacts, so simultaneous verification cannot invalidate another run.

The counts can be set by `MODEL_SCHEDULES`, `MODEL_PROBE_SCHEDULES`,
`MODEL_MUTATION_SCHEDULES` and `MODEL_SEED`. Defaults are 1000, 2000, 100
and 697. Run this local gate in addition to the generic repository model gate.

For focused checks:

```sh
python3 protocol/models/remote-execution/run.py --help
python3 protocol/models/remote-execution/run.py --schedules 1000 --probe-schedules 2000 --seed 697
python3 protocol/models/remote-execution/run.py --case tcFaults --schedules 10000 --seed 698
python3 protocol/models/remote-execution/mutate.py --list
python3 protocol/models/remote-execution/mutate.py --schedules 100 --seed 697
```

Every checker invocation is equivalent to this command, run inside the
isolated snapshot, with an absolute output directory:

```sh
p check --testcase tcFaults --schedules 1000 --max-steps 1000 --fail-on-maxsteps --seed 697 --timeout 60 --memout 1 --outdir <case-output>
```

Direct use follows the existing terminal-attachment model:

```sh
cd protocol/models/remote-execution
p compile --pproj RemoteExecution.pproj
p check --testcase tcLifecycle --schedules 1000 --max-steps 1000 --fail-on-maxsteps --seed 697
```

The existing `scripts/model_check.sh` can discover this `.pproj` and its
`PTst` cases without edits, including the expected-failure `tcProbe*`
convention. Its generic probe check accepts any nonzero exit, whereas the
local gate verifies the exact assertion marker and checker statistics. The
local gate also runs mutations, which the generic runner does not.

Logs, source snapshots, DLLs, trace JSON and replayable `.schedule` files live
under ignored `PCheckerOutput/gate-*/` and `PCheckerOutput/mutations-*/`.
`results.json` records commands, working directories, exit codes, schedule
counts, assertion text and elapsed time. Mutations retain their source copies
and compiled DLLs for independent replay. For example, from the saved mutant
project, use `p check --replay <absolute-schedule-file>`. A probe or mutant
checker returns 1 for its expected assertion; the validating Python script
returns 0 only after verifying that evidence.

## Actors and durability boundary

| Actor | Responsibility |
| --- | --- |
| `Owner` | Store the execution handle before dispatch; retain it across reconnect/restart; commit delivered terminal outcome before sending receipt. |
| `Executor` | Own the two-row durable ledger, admission epoch fence and launch intent; reconcile existing IDs, observe native evidence, accept receipt and compact safely. |
| `Helper` | Own one native slot reused by multiple executions; report start, terminal outcome and descendant retirement; delay cancellation delivery until the slot may have been reused. |
| Directed scenarios | Wait for actual protocol replies, exercise missing evidence and crashes, and finish through real receipt/cleanup transitions. |
| `FaultScenario` | Inject twenty finite fault/control actions among independent actor messages, including dropped wire traffic and arbitrary restart/reconnect ordering. |

An execution key contains session, workspace, operation, execution and executor
identities plus separate session/workspace epochs. `tRequest.digest` binds
request content but is outside the map key. A reused key with a changed digest
conflicts. Connection incarnation (`Owner.connection`) and executor boot
incarnation (`Executor.boot`) are neither part of the logical identity nor
permissions to repeat a launch.

Ledger writes are atomic abstract durable commits. Admission writes a row
before acknowledgement. A separate executor turn records launch intent before
sending native start. The queued authorization carries the current boot;
reboot invalidates an authorization that has not recorded intent. An intent
already committed cannot return to `Admitted`, even when no native process was
observed. A start already sent to the helper may execute after reboot; it is
the original start, not a recovered launch. Native evidence names the original
logical key and launch boot, so a new executor boot can reconcile that work.

`eCrash` preserves ledger, closure and epoch high-water mark, then advances the
boot. It abstracts reconstruction rather than terminating a P actor. The model
preserves routing hints to publish recovery views, but those hints do not
permit launch. Reconnect changes connection and refreshes routing by exact-ID
retry. Replies from an obsolete connection are discarded without deleting
custody. Owner restart similarly preserves its custody and outcome stores.
Native work survives an executor crash.

Terminal result (`Succeeded` or `Cancelled`) and native retirement are separate
facts. The helper can report success while still retaining the native slot.
Cancellation itself supplies no retirement proof. Receipt is accepted only
after the owner has committed the delivered terminal result. Lost result or
receipt traffic retains the row and its reserved capacity.

Closure is permitted while rows remain uncertain or active. It rejects new IDs
and first-launch authorization, but exact retained IDs still reconcile before
closure/capacity checks. Individual row GC requires closure, terminal outcome,
retirement and receipt. Whole-epoch GC/advance checks every outstanding row,
collects only safe rows, and advances both epochs without deleting the durable
high-water mark. Old epoch requests stay fenced after GC and reboot. The model
then reaches a successful execution in the next epoch, so the fence is not
implemented by permanently refusing all work.

The helper's pending-cancel queue has capacity two; additional cancels are
left unconfirmed. A cancel admitted for the first live execution is delivered
after the second has started in the same slot. The key and launch boot must
match the active native identity before cancellation takes effect.

## Monitors and executable scenarios

The monitors retain independent historical facts after row GC; they do not
trust the executor's `rowSafe` flags to verify its own compaction decision.

| Monitor | Checked claim |
| --- | --- |
| `AdmissionSafety` | Owner custody precedes admission; durable matching admission precedes ack; exact duplicate preserves prior request; changed digest conflicts; retained capacity is at most two; closed/old epochs cannot become new admissions after GC. |
| `LaunchSafety` | Durable admission and one durable launch intent precede native start; at most one native start per logical execution; reboot preserves intent; closure prevents first authorization. |
| `ReceiptSafety` | Durable owner outcome precedes receipt acknowledgement; terminal outcome, actual retirement, receipt and durable closure all precede GC; epoch advance cannot discard outstanding rows. |
| `CancelSafety` | A cancel's complete native identity matches the active execution when it acts. |
| `DirectedProgress` | Finite reliable scenarios finish, including recovery which intentionally remains uncertain. No progress claim is attached to lossy traffic. |

| Normal case | Schedule exercised |
| --- | --- |
| `tcLifecycle` | Actual native start, active reboot, delayed stale cancel, helper reuse, two successful results/receipts/retirements, capacity refusal and digest conflict, closed reconciliation, row GC, post-GC reboot/fencing, epoch GC/advance and a third successful execution. |
| `tcCrashAfterSend` | The same successful lifecycle, with a reboot after each native start send and before the executor consumes native observation. |
| `tcUncertain` | Crash after intent and before native start; reconnect and exact duplicate preserve uncertainty; close permits reconciliation; unsafe row GC and epoch advance are refused. |
| `tcReceiptPending` | Retired native work with a retained successful terminal result; GC is refused before owner receipt and succeeds after it. |
| `tcRetirementPending` | Owner receipt of a successful result while native custody remains; GC is refused until actual retirement. |
| `tcFaults` | Bounded nondeterministic requests, reconciliation, reconnect, both restarts, drops, native completion, retirement, delayed cancels, closure, GC and advance while queues remain in flight. |

Thirteen `tcProbe*` cases assert that a significant state never occurs, then
intentionally fail when it occurs: complete success through receipt/cleanup
and epoch GC, both launch-crash boundaries, a reboot with actually running
native work, stale cancel delivery after reuse, capacity refusal, closed-epoch
same-ID reconciliation, changed-digest conflict, and admission request/acknowledgement, result/cancel/
receipt transport loss. They are checked separately from safety, so the
expected assertion cannot conceal a safety failure in the normal cases.

## Mutation witnesses

`mutate.py` copies the model before editing one source site. It first requires
the selected unmodified case to pass, then compiles the mutant and requires
the intended monitor assertion. Monitor sources are unchanged. It never edits
or restores live model sources or git state.

| Mutation | Real transition changed | Intended case and assertion |
| --- | --- | --- |
| `relaunch-uncertain` | An exact duplicate resets its row to `Admitted` and queues another authorization. | `tcUncertain`: `uncertain launch was automatically retried`. |
| `stale-cancel` | The helper ignores the requested key/boot when delivering a queued cancel. | `tcLifecycle`: `stale cancel acted on reused helper's newer execution`. |
| `gc-without-receipt` | Compaction no longer requires owner receipt. | `tcReceiptPending`: `terminal GC without owner durable receipt acknowledgement`. |
| `gc-without-retirement` | Compaction no longer requires native retirement. | `tcRetirementPending`: `terminal GC without native retirement`. |
| `forget-closed-epoch` | Reboot reopens the old admission epoch after row GC. | `tcLifecycle`: `same logical execution admitted again after GC`. |

## Recorded verification

The final local `bash protocol/models/remote-execution/check.sh` run on
2026-10-04 exited **0** with the default counts and seed 697. All six normal
cases explored 1000 schedules and reported zero bugs (checker exit 0).
All thirteen probes reported their exact expected assertions (checker exit
1): receipt loss needed 14 schedules, cancel loss needed 3, and the other
probes needed 1. Each of the five mutation controls passed 100 schedules;
each mutant compiled successfully and failed its intended assertion on
schedule 1 (checker exit 1). Every P compilation exited 0 with no warnings.

The saved evidence is `PCheckerOutput/gate-20261004T084831973113/results.json`
and `PCheckerOutput/mutations-20261004T084932145007/results.json`. Source
snapshots and schedules beside them permit independent checking and replay.
The baseline invocation took about 60 seconds; mutation controls, compilation
and witness checks took about 28 seconds. These are local model results;
independent review, integration and hosted checks are separate.

## Bounds, schedules and omissions

There is one owner, executor, session and workspace, one reused native helper,
two retained executor rows, and at most two buffered native cancels. The
lifecycle uses three logical executions across two paired epochs plus one
capacity-refused ID, and tests two request digests. Fault traffic uses up to
six logical IDs and four epoch pairs `(1,1)`, `(2,2)` and the mixed pairs `(1,2)` /
`(2,1)`; the model may advance from epoch 1 to 2 once. Operation/execution IDs
are separate fields, but these scenarios give them equal numeric labels.
Session/workspace/executor identity and enrollment are fixed, not a security
model for arbitrary identities.

Fault traffic begins with five prepared requests and issues twenty subsequent
actions; an action may prepare a sixth mixed-epoch ID. All message production is finite; each incoming request
can produce only a fixed finite chain of replies/native observations. P
inboxes have no explicit production backpressure algorithm here: their total
traffic is bounded by this finite workload (a conservative 512 enqueued
messages across the scenario), while the explicit ledger/cancel queue bounds
exercise retention pressure and control loss. This is not a proof of byte,
stream or disk quotas. The checker separately fails a run reaching 1000
scheduling steps, 60 seconds or 1 GiB. Compilation has a 120-second outer
deadline.

P's default random scheduler uses seed 697. These are bounded bug-finding
runs, not exhaustive state-space exploration. Reliable directed scenarios
contain no nondeterministic loss; their repeated schedules may share one
logical timeline. Their progress check assumes eventual scheduling of enabled
actors and reliable local evidence delivery. Lossy traffic has no eventual
delivery/fair-cleanup assumption and no unconditional liveness claim. A
retained unknown execution or full ledger is a permitted safe stopping state.

The model assumes trusted crash-faulting participants and intact durable
storage. It omits authentication, enrollment, Byzantine executors, digest
cryptography/collisions, actual output/result payloads and result-digest
validation, disk corruption/torn writes, database CAS implementation, process
and descendant enumeration, native helper death/reboot, arbitrary delayed
native result duplicates, deadlines/renewal, stream byte bounds, filesystem
operations, executor placement and authority consensus. Native retirement is
an abstract trustworthy witness. Native result reporting precedes native
retirement reporting in these helper scenarios; they do not cover reversed
observation order. Request/reply loss occurs at sending boundaries; a separate
transport machine and unbounded partitions are omitted. None of these omitted
mechanisms is implemented or proved by D2.

## Model-to-code mapping

| Model transition | Implementation boundary |
| --- | --- |
| `Owner.ePrepare`, custody store | Future remote dispatcher durable handle, before any send; preserve the local `StartRefusal` meaning from `broker/dispatch`. |
| Full key and request digest | `executor/remote/identity.gleam` validated scope/key/digest constructors. Identity construction does not grant authority. |
| `Executor.admit`, prior-state lookup, conflict/capacity checks | `executor/remote/admission.gleam` pure `admit` / `inspect` over a bounded `Book`. |
| `Executor.eLaunch`, irreversible intent | Pure `reduce(..., AuthorizeLaunch)` decision plus a future serialized durable adapter which commits the next Book before performing the single launch effect. Recovery must not perform a persisted effect again. |
| Native terminal/retirement and owner receipt | Pure `ObserveTerminal`, `ConfirmRetirement`, `ConfirmOwnerReceipt` transitions; future actors supply actual evidence and commit before acknowledgement. |
| Closure before first authorization | Pure `close(book)`; retained IDs may still inspect. P omits the definite refusal path described below. |
| Individual row GC and whole-epoch advance | Future adapter only. The pure Book keeps `Retired` tombstones and does not free capacity or implement epoch replacement. The model's permanent epoch fence is a separate durability requirement. |
| Delayed helper cancellation | Future remote control envelope plus the existing local execution fence; the model binds logical execution and launch boot at the helper boundary. |

This table records the intended bridge, not a claim that the model executes
the pure remote modules. The model
has a durable `Running` observation and abstract native identities, whereas
the reducer can retain `LaunchIntent(NativeUnconfirmed)` until terminal
observation. Both prohibit reauthorization. The reducer can retain retirement
before terminal; that additional ordering is outside this helper model.
Persistence/network actors, real remote-host tests and a differential
model-to-code bridge remain future work.


### Pre-launch refusal is covered by Gleam tests

If closure or reboot precedes the queued first `eLaunch`, P can retain an
`Admitted` row indefinitely. The model has no `RefuseBeforeLaunch` transition
and makes no progress claim for that ordering. Its successful scenarios do
not establish that every admitted request can settle.

The actual Gleam reducer handles this case with separate `Refused` and
`RetiredRefusal` phases. Refusal proves native absence only before any launch
intent, remains available after closure, and still requires durable owner
receipt before compaction. The `remote_admission_test.gleam` regressions and
bounded event enumeration exercise that implementation, including rejection
of refusal after live or recovered launch intent. That refusal/receipt/
compaction path is tested code, not a property checked by this P model.
