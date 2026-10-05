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
all registered mutations. It exits zero only if every check succeeds. Compiler
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

`mutate.py` copies the model before applying each specified mutation. Most
mutations change one site; the recovery-routing control changes three exact
sites while preserving the existing path instrumentation. It first requires
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

The original native-only local `bash protocol/models/remote-execution/check.sh` run on
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


## Semantic workspace product composition

[PRODUCT.md](PRODUCT.md) records the additive ProductSystem actors, finite
classes, safety histories, eight normal cases, nine positive controls and
nine product mutations. That snapshot preserved existing System actors, native monitors and test
sources byte for byte; the later Compile custody extension below splits only
the native Executor terminal payload/commit decision. The original product snapshot had 36 cases and fourteen mutations. The
preparation extension below adds directed cases and controls; the current
runner now discovers 79 cases and checks thirty mutations in total.
Source manifests beside the immutable snapshots record SHA-256 hashes.

ProductSystem joins the existing Owner, Executor and Helper with ProductOwner
and ProductExecutor. Actual native start, terminal and retirement remain events
of those original actors. Outer completion and its owner receipt use separate
product facts. These checks do not establish production assembly or the
separate-host product acceptance gate.


## Preparation, exact wall and native association

The preparation extension keeps the original native actors, their four safety
monitors, and every existing native/product case. `ProductExecutor` now has two
service-keyed preparation rows. It commits Preparing before a separate creation
turn, then commits Ready in another turn. CompileLocations therefore precede
CompileCommand. The compiled artifact follows native Compile completion and
must match retained Launch input before Launch preparation. The exact result
digest class and its separately issued artifact class are both compared;
matching the result digest alone cannot admit a substituted artifact. A distinct executor
fingerprint check precedes native Satellite start. The model does not represent
source files, sockets, token bytes or hash cryptography.

A live Launch resource owner is separate from its durable issued lease and from
the executor control actor. Control restart revokes unfinished claims without
killing that independent resource owner. Its death makes a Ready lease unusable;
historical issue evidence remains. Ready reply loss while the owner is live
returns the exact original lease. Compile creation/crash/readback and Compile
Ready/reply-loss/readback now have separate directed cases and historical probes.

ProductOwner constructs an offer from accepted Ready and retained service input,
selects its exact positive wall, and retains that offer before a separate
clearance turn. There is no executor confirmation of the owner-built offer.
The original deadline and ceiling remain in service input; the final wall stays
in the immutable offer. Actual forwarded native admission evidence, naming the
exact retained key/digest, creates the physical service association. Clearance
alone cannot establish it. Outer completion must use that association.

Time is injected as finite elapsed events. With the selected model contract
`E=5000 ms`, `S=38000+2E=48000 ms` and `C=180 s`, selection is
`min(C, floor((R-1100-S)/1000))`, refusing below one second. Seven directed
Ready-time remaining profiles are 0, 50,099, 50,100, 150,000, 229,099, 229,100 and
270,000 milliseconds. They check refusal, positive-one-second and cap/floor
boundaries, preparation-driven shrinkage and the cold 180-second wall. The
300-second original budget, 30-second preparation, six-second control/start
allowance actually spent, and seventy-second compile duration reach actual
native start and exact Compile completion. The modeled elapsed events are
abstract durations, not measured compiler performance or hard real-time bounds.

The 120-second delayed-first-clearance trace refuses the same retained
180-second offer twice, including recovery, without a native identity. A separate
post-start delay/restart trace queries its original native key and exact offer
without clearance. These witnesses retain independently observed creation,
Ready, elapsed, native start and query histories rather than trusting scenario
stage labels. `PreparationSafety` also checks immutable original authority,
wall fit at clearance/native start, actual native admission, producer association,
and dead-resource usability. Exact byte encodings and real clock assembly still
need implementation tests.

There are at most two outer rows, two preparation rows, two retained offers,
two native associations and two native rows. Preparation has five retained
phases plus absence, so at most 36 phase pairs before reachability constraints.
The helper still has one active native slot and two pending cancels. Each timing
case has one fixed initial preparation delay and at most one recovery delay;
there is no millisecond tick loop or unbounded retry producer. The existing
mixed-fault workload retains its twelve actions. A conservative updated traffic
bound reserves 256 messages for bootstrap/fixed completion chains and 32 for
each of twelve actions, totaling 640 messages. Exact duplicate responses cannot
create repeated receipt producers. This is finite workload accounting, not a
production mailbox, disk or resident-memory ceiling.

The preparation snapshot had **71 cases**: 31 normal cases and 40 exact
positive probes. The Compile custody addendum below retains them and adds eight
cases, bringing the current total to 35 normal cases and 44 exact positive probes. The mutation runner preserves all fourteen previous mutations
and adds thirteen decision mutations: Compile construction before Ready, Compile
recreation, dead issued lease reuse, foreign producer association, foreign issued artifact, bad
fingerprint acceptance, initial-budget reuse, rounded-up wall, clearance as
admission, foreign native terminal, wall reselection, deadline renewal and
clearance after native custody. Every mutant must compile and fail its exact
intended assertion after the corresponding unmodified control passes.

The foreign-terminal case delivers the existing same-key/digest-2 class to the
real service terminal handler. Its normal control requires actual refusal before
genuine Compile completion, and its positive probe independently witnesses that
ordering. Removing only the equality guard admits the foreign input. The
re-clear mutation reroutes recovery into `clearOffer` and removes its native-custody
and prior-clearance guards; the existing clearance instrumentation remains intact.
Earlier versions of these two mutations injected false announcements and did not
establish the claimed handler or recovery-path failures. Their original recorded
gates remain historical evidence, subject to this correction.

Runner limits remain 1,000 scheduling steps, 60 checker seconds, a 65-second
outer checker deadline and a 1-GiB checker memory bound. Compile has its separate
120-second outer deadline. Each invocation records scheduling-point statistics,
wall duration and, on macOS with `MODEL_MEASURE_MEMORY=1` and the existing `/usr/bin/time`,
per-invocation peak resident bytes. This measurement needs permission for
macOS resource statistics; ordinary runs omit measurement and retain the
checker memory limit. Measured process memory is separate from the checker limit.
Final source hashes, actual counts and gate exits belong in the frozen evidence
report; a small smoke run does not establish the default gate.

Channel PlusCal, the other distributed-authority algorithms and the existing
Lean admission proof/684-case bridge are unchanged. This P extension introduces
no new proof project, and proves no production refinement. The selected control
allowance must be rechecked against concrete serial calls before physical
assembly can rely on its successful-path schedule.


## Compile custody settlement extension

`CompileCustodyScenario` adds four directed controls to this same project.
`CompileCustodySafety` records independently owned resource, native terminal,
completion and receipt histories. Existing Owner/Helper/native monitors and all
31 normal cases, 40 probes and 27 mutants remain. Native Executor's only semantic
extension is the actual terminal payload/commit split; the three new decision
mutants bring the current total to 30. The full gate has 79 cases.

Compile completion now has explicit BeforeNativeFailure or NativeCompletion
provenance. An original live Preparing claim can atomically retain a Before error
and become ResourceUncertain, revoking that claim and fencing queued late Ready.
Once Ready exists, absent resource/native association is not a negative Submit
fact. Recovery grants no claim; exact retained error retries/readback do not
consult native liveness. Native-associated completion still requires the exact
associated child and actual native terminal evidence. The model uses equality
classes, not encoded bytes or physical artifacts.

Native Executor first retains its actual terminal payload and then commits its
row's Terminal outcome/result digest in a separate turn. The paused mode permits
a crash and real row query between those decisions. Product settlement compares
the exact association, payload and row terminal digest. The native actor alone
announces payload/terminal commit facts. Prepared digest 1, native terminal digest
3 and outer result digest 2 remain distinct symbolic classes. Terminal payload
retention alone cannot settle an outer Compile. Existing native refusal/compaction
production variants and real SQLite commit failures are outside this extension.

| Directed case | Actual transition witness |
| --- | --- |
| `tcCompileFailPreparationLateReady` | Live create, atomic Before error, real late Ready refusal, recovery and exact historical error readback/ACK. A second branch crashes before error and refuses a recovered claim's failure attempt. |
| `tcCompileReadySubmitUnassociated` | Canonical Request/Prepared with missing native readback refuses association; actual native admission/Running Submit remains locally unassociated and cannot accept Before; releasing the exact association permits normal native completion. |
| `tcCompileTerminalPayloadPending` | Native-owned payload survives reboot with Running row; real settlement refuses it before reducer commit, then accepts the same exact payload after native terminal commit. |
| `tcCompileIndependentReceipts` | Original Compile outer ACK and resource Released leave actual native receipt/retirement false; the existing Launch row supplies the converse native receipt/retirement with outer ACK pending, then exact ACK survives recovery. |

Each case has an exact positive probe requiring these owned histories and actual
readbacks. The receipt control reuses the existing two-service Compile/Launch
product rather than adding another service identity or resetting a receipt.
Before-error ACK is exercised separately by the first control. Outer receipt
changes only a retained outer ACK set; cleanup changes only preparation/cleanup
state, preserving completion and Ready history. Neither changes native rows.

The three new compiling mutants weaken real decisions: accept late Ready after
Before, accept Before after Ready when native association is absent, or settle
matching terminal payload without committed reducer evidence. Each original
control must pass; each mutant must compile and fail its exact assertion, with
monitors unchanged. No optional replacement mutant is needed because the existing
native completion map guard is unchanged; historical Before retry adds no result
replacement path. The old clearance-as-admission mutation now supplies the changed
typed readback shape, but still reaches the real handler and independent admission
history without emitting a fabricated native monitor fact.

Run these through existing run.py/mutate.py and then check.sh at unchanged strict
defaults. New source adds at most two retained native payloads, two outer ACK bits
and finite directed control chains, with no ticker or retry loop. The earlier
640-message preparation snapshot bound above is historical; the current runner's
1000-step bound and measured scheduling-point statistics apply to this extension.
Passing this bounded model is not production journal, transport, cryptographic,
filesystem, crash-atomicity or full refinement proof. Actual process exits,
schedule counts, probe points and source hashes belong in the frozen handoff.

## Original live association before command launch

The command lane extends the shared native Owner and Executor rather than copying
an execution engine. Ordinary native Submit follows its prior path. A command
Submit retains the complete original prepared product, commits native Admitted,
and asks the resource actor to associate through the original live Claim. Resource
association commits before its one original permit answer. Native Executor consumes
that exact answer once, under its original pending continuation and boot, before
committing native Intent or sending helper start.

Creation custody and live association have distinct lifetimes. The creation claim
ends at Ready; the original association continuation survives Ready and ends at
association, fence, resource-owner death or resource actor restart. Retained Input,
Ready and association readback never issue another live Claim or permit. The native
route retains full prepared identity but no live Claim; pending original callbacks
and launch permits are volatile. Abandoned replies remove the original callback.
Reboot clears pending callbacks and queued eligibility. A delayed old-boot answer
can be refused while its exact resource association remains historical data.

The initial reserve-to-Preparing handler issues a Claim only for a newly inserted
outer row. This is an atomic abstract transition, not a proof that production's
separate reserve/claim APIs already enforce original first-service authority. Whole
Compile initial admission/recovery and cancel-before-first-Submit belong to a
separate implementation bridge. This extension does not broaden their model scope.

Every closed Query, Cancel, Receipt and abstract Stdin control, plus duplicate
Submit's historical readback, checks full prepared identity against the retained
resource association. The model has no stdin bytes, ordinals or credit algorithm;
its claim is guarded forwarding only. A native UUID cannot be reinterpreted as a
different command after recovery. No retry selects a new command, wall or deadline.

Fence-before-association refuses eligibility. Association-before-fence preserves
its exact native cancellation route and may still reach helper start. This model
continues to omit production Refused-before-launch: it makes no stronger promise
that a post-association cancellation prevents all OS effect. Original native
retirement and receipt histories remain distinct from resource cleanup.

The existing `tcCompileReadySubmitUnassociated` now pauses actual Admitted before
association, rather than allowing Running first. Its Request-only refusal,
Ready-plus-in-flight Before refusal and exact resumed native settlement remain.
Four additional normal cases cover cancellation order, lost/stale reply recovery,
changed Claim/duplicate association, and four hostile controls delivered against
two genuine associations. Seven positive probes require actual claim/association,
permit consumption, helper start, fence/refusal and native readback histories.
They do not accept scenario stage alone as evidence.

The independent PreparationSafety histories check original Claim identity and
revocation, actual Admit, exact association, unique permit issuance, one-shot
consumption, original boot, abandoned reply, Intent and closed control forwarding.
The old native/product/custody monitors and all earlier cases remain active. All
thirty prior mutation names remain; `preparation-clearance-as-admission` now skips
the actual native Admit commit in the closed path, rather than sending an obsolete
legacy fake-admission event. Seven additional mutations change actual launch,
association, Claim, duplicate, boot, abandoned-answer and control decisions. Each
must compile and fail its intended independent assertion; mutation compiler errors
remain gate failures. The local run.py additions register exact probe markers only;
runner.py, outer scripts, PlusCal and Lean mechanics are unchanged.

The added traffic is finite: at most two retained native/resource rows, one helper,
two resource Claim incarnation classes and one original pending continuation per
native key. The control case bootstraps both genuine associations, sends four
hostile controls serially, then reads the genuine second native row before allowing
completion. No feedback loop or ticking actor is added. The existing 1000-step,
60-second, 1-GiB checker bounds stay unchanged; verification reports the observed
scheduling-point census separately from this workload description.

The model retains its historical illustrative 48000 allowance profile to preserve
its exact wall tests and prior evidence. Production startup authority is now
S=44000+W+2E (59000 at W=E=5000), after the owner service_child ask was included.
Neither the old profile nor these schedule-based checks prove production timing,
codec correctness, TLS authentication, native tickets, database transactions,
physical OS enforcement or whole Compile refinement.

## Owner-run discharge prerequisite

The additive `RunCustodian`/`RunDownstream` model checks the separate owner-run
marker implemented by `client/remote/custodian` and `storage/owner_custody`.
It preserves all 90 earlier cases and 37 earlier mutations. Eight normal cases
and eight exact positive probes bring the total to 106 cases (47 normal and
59 positive probes); nine additional decision mutations bring the total to 46.
`runner.py`, existing P machines/monitors/tests and checker bounds are unchanged.

Fresh COMMIT writes Unreleased before the separate worker-start turn. Only an
exact final COMMIT and AllDelivered observed by the admitting incarnation may
release it. Worker loss, consumer fatal, failed final COMMIT and failed discharge
COMMIT fence the owner; ordinary final history cannot overwrite that disposition.
Restart preserves rows and erases live reports. Any unreleased row makes fresh
admission recovery-only. Collection requires Released and preserves the marker.
A runner's original pinned incarnation refuses replacement-owner child requests;
external history and an exact late child receipt remain usable.

The controls exercise normal finish/drain and capacity reuse in the same live
incarnation; early collection refusal and frozen-marker preservation; Fresh
COMMIT/pre-spawn crash; final COMMIT/pre-drain crash; independently accepted
held downstream work followed by worker loss and owner restart; sticky consumer
fatal followed by ordinary final; failed final and discharge COMMIT; and failed
Fresh COMMIT followed by genuine later execution. The lost-worker control reads
back the exact original late receipt after rejecting a stale pinned request.
Every step waits for an actual actor reply. Positive probes retain independent
commit, start, drain, fence, restart, refusal, receipt and collection histories;
scenario stage labels never establish these facts.

The additional mutations alter actual reservation, final, discharge, collection,
startup and pinned-child decisions. They omit the Fresh marker, release on final
before drain, reset startup admission, overwrite fatal disposition, collect early,
ignore final/discharge COMMIT failures, rebind an old pinned runner and commit
changed final bytes. Monitors are unchanged in each mutant snapshot. Each
unmodified control must pass; each mutant must compile and fail its exact
registered assertion. Missing witnesses and unrelated assertions fail the gate.

This is a bounded contract model. It has one owner, one independent downstream
actor, at most two durable tool rows, one live slot, two incarnation classes,
one accepted downstream origin and one rejected origin. The longest script has
11 owner operations plus a finite reply chain. There is no retry producer,
ticker or partition-recovery liveness claim. The same strict 1,000-step,
60-second, 65-second outer and 1-GiB checker limits apply. Directed schedules
may repeat the same logical trace; random scheduling is bug-finding, not an
exhaustive state-space or temporal fairness proof.

The custody assumptions are explicit: journal operations commit atomically or
fail without changing durable bytes; reported COMMIT status is truthful; final
payload integers represent exact bytes without collisions; one managed worker
has at most one ordinary final report; AllDelivered belongs to that original run;
and a pinned incarnation represents an unforgeable original Subject/PID. The
model checks decisions consuming those facts, not their SQLite, weft or BEAM
implementations. A failed final can be simulated directly; actual crash and
COMMIT-failure production witnesses supply the complementary code evidence.
Downstream custody and its exact receipt evidence are independent of worker
lifetime. The production child-row receipt COMMIT/readback is a separate code
witness; this model does not equate its downstream history actor with that SQL
API. AllDelivered is not native
retirement, OS cleanup or proof that every physical command has stopped.

The exact model/code bridge, frozen production hashes, observed schedule counts,
mutation witnesses and independent review belong in
[the owner-discharge model review](../../../docs/review/distributed-owner-discharge-model.md).
This extension does not prove native retirement, Compile/Launch cleanup,
authentication, codecs, kernel isolation, separate-host acceptance or whole-system
refinement. Old-format product refusal remains a production witness; this model
starts with a supported-format journal and supplies no migration authority.

The owner-discharge snapshot's full local strict gate exited 0 in 510.13 seconds
with all 106 cases validated, all 46 compiling mutants killed and no skipped
case. Peak observed RSS was 318,799,872 bytes. Fresh independent Astra review
found no actionable findings within the stated abstraction. The review page
and `owner-discharge-model-final-verification.json` record exact source hashes,
model versus measurement exits and replayable evidence.

## TLS BEAM endpoint credits

`BeamCredits` models the endpoint's local handoff and admission boundary. Four
Data credits and two Control credits are shared by every registered scope.
A credit contains one current transport reference and at most one admitted
service ask. A delayed local handoff retains its original reference even if the
transport has joined and the same credit now serves another scope.

| Model transition | Implementation boundary | Claim |
| --- | --- | --- |
| `CreditReserve` | `beam_endpoint.reserve` | All scopes share the same finite credit lists; quiescing refuses new admission. |
| `CreditHandoff` | `handle_credit` and `admit` | Only the current reservation reference can admit an ask. A stale handoff leaves the current assignment unchanged. |
| `CreditConsumerGone` | `weft.cancel_when_exits` | Caller death supplies neither an actual service answer nor a joined-run witness. |
| `CreditAnswer` | `native_replied`, `workspace_replied`, `compile_replied` | Only the actual service answer removes an admitted ask. |
| `CreditDrain` | `network_finished` | `AllDelivered` ends local transport ownership; it does not imply delivery of a message from another sender. |
| `maybeRelease` | `available` | Reuse requires no pending service ask, a joined transport run and no retired disposition. |
| `CreditRunLost` | `handle_credit` on run/service loss | Loss retires capacity; later observations cannot reopen it. |

Four directed safety cases exercise stale handoffs both while idle and after
reuse, caller loss with an unresolved ask, capacity shared across two scopes,
and sticky retirement. The stale-handoff case explores both answer-before-drain
and drain-before-answer orders. Each scenario checks the actual response and
capacity after every step. Four separate reachability probes require their
precise final witness, and six compiled mutations remove individual protections.

This is a bounded scheduling model, not a proof of OTP signal delivery, TLS,
canonical byte decoders, SQLite commits or native retirement. Service answers
and `AllDelivered` are truthful external observations. Run references are fresh
within one endpoint lifetime; restart does not inherit its credits. The lost-run
case conservatively allows later answer/drain observations even though the
production credit actor has stopped. No message-ordering theorem across different
senders is assumed. Concrete delayed-handoff tests and the other custody models
remain necessary to connect this abstraction to the implementation.

The focused credit-model gate exited zero with four normal cases at 1,000
schedules each and four exact reachability witnesses. All six compiled mutants
failed their intended assertion after an unmodified control passed. Evidence is
`PCheckerOutput/gate-20261005T030313867247/results.json` and
`PCheckerOutput/mutations-20261005T030356990572/results.json`. These checks
cover the credit extension only; the previously recorded full model gate belongs
to its earlier source snapshot. Independent Sol review reproduced all of these focused checks and found no
confirmed model-to-code defect within the stated limits.

### Proposed scoped lifetime correspondence

The scoped extension specifies the proposed local lifecycle in the
[scope lifetime note](../../../docs/design-notes/distributed-scope-lifetime.md).
Its endpoint API and native close-state correction await owner approval. These
new transitions have no executable runtime bridge yet. They do not establish
native retirement, journal release or successful production host shutdown.

The model retains six authoritative credit slots and sixteen fixed scope rows.
Every row starts Active and can become permanently Fenced; no command removes,
rebinds or revives it. Scalar scope/run IDs stand for exact administrative row
identity and original correlation. The model assumes those associations were
validated; it does not verify registration constructors or concrete owner PIDs.
A slot whose run is zero and whose retired flag is set represents Unusable(None).
A retired slot retaining its original run/scope represents
Unusable(Some(original assignment)). Neither state can restore capacity.

| Proposed transition | Checked property |
| --- | --- |
| `CreditFenceScope` | Applied fencing refuses this scope before another shared credit is consumed; siblings remain eligible. |
| `CreditOwnerDown` | The applied owner-monitor notification fences the same row, including when no credit is assigned. A reservation may already have won before that notification is applied. |
| `CreditSnapshot` | Active rows are Busy. Fenced rows are Uncertain if an unusable slot retains their original assignment, Busy if an assignment remains, and otherwise Drained. |
| `CreditServiceDown` | Loss supplies neither an actual answer nor a joined producer; the scoped original assignment stays uncertain. |
| `CreditCreditDown` | Idle death reduces capacity without inventing a scope obligation. Busy death retains the original assignment and uncertainty. |
| Exact completion observations | Stale answer/drain correlation cannot alter a reused slot or discharge its current assignment. |

The independent monitor remembers applied fences, original run-to-scope
associations, current assignments, actual answer/drain observations and sticky
retirement. It checks a Drained snapshot against that history, rather than
trusting the implementation's slot flags. Drained is a scoped transport/service-ask
fact only. No free-credit count, caller timeout, owner DOWN or service DOWN can
substitute for it. Native and Compile/workspace continuation lifetimes remain
separate obligations.

Six directed cases and exact reachability probes extend the original four
credit cases without replacing them:

| Case | Concrete bounded history |
| --- | --- |
| `tcBeamScopeFence` | A held original run, scoped refusal, sibling progress, joined unhanded-off run, delayed stale handoff, permanent repeated fence, and valid/invalid scope-table boundaries. |
| `tcBeamScopePending` | Caller loss and both answer-before-drain/drain-before-answer orders; each intermediate snapshot stays Busy, then the original scope drains while a sibling remains active. |
| `tcBeamScopeLost` | Service DOWN, later actual answer and drain, persistent scoped uncertainty, and independent sibling drain. |
| `tcBeamScopeStale` | Old answer/drain arrives after reuse by a fenced sibling; its current assignment remains Busy until exact completion. |
| `tcBeamScopeIdle` | A previously completed scope stays Drained after its idle credit dies; busy credit death retains a different scope's original uncertainty. |
| `tcBeamScopeOwner` | Idle owner DOWN fences its row; busy owner DOWN fences a previously assigned row, which remains uncertain after credit death, while another scope uses the remaining capacity. |

Four new compiled mutations remove the scoped gate, treat DOWN as drain,
forget retired scoped disposition, or accept a stale completion. Existing
credit cases, probes and six mutations remain registered. The standard model
runner discovers the added cases; every probe requires its exact final marker,
and every mutation requires an unmodified passing control and its intended
independent-monitor assertion. Focused results for this extension are recorded
separately from the older full-model gate above.

## Complete-report custody

`OwnerDischarge` now models an immutable final profile selected before Fresh
admission. Ordinary tools reserve their original final allowance. Code mode
reserves 17,301,648 bytes for a complete report, bounded final message and stored
bookkeeping. This fixture admits two such full allowances; identity/request and
child reservations remain outside its arithmetic. The real owner quota also
charges those separate obligations.

Report COMMIT, final-reference COMMIT, wrapper drain and exact session readback
are separate events. A lost report acknowledgement preserves report history
without inventing the missing final message. Failed retention keeps the run
unresolved even when a later diagnostic is stored. Collection preserves the
report's identity, digest and actual byte charge; reboot preserves the complete
durable row and invalidates the old worker pin.

A no-terminal refusal is a distinct branch. `RunPrelaunchProducer` observes the
trusted vet or compile refusal before the owner accepts its exact original
pin and stage. The final sender cannot create that observation by choosing a
tag. `RunStart` represents the wrapper process, so a compile refusal may follow
both wrapper startup and native compiler work. The model does not infer native
cleanup from that refusal. Its producer event abstracts the real trusted renderer
branch; runtime tests must establish that correspondence.

`ReportCustodyScenarios` exercises complete-report retention, lost replies,
failed commits, wrong profiles, oversize values and quota pressure. The refusal
controls exercise both legitimate stages and reject unclassified or forged
report-free finals. Independent monitors retain producer, commit and collection
observations. Reachability probes require those observations and completed
replies, never the driver's step counter. Guard mutations leave those monitors
unchanged.

Report and digest identities are symbolic atoms. Byte counts are concrete, but
this model does not implement SQL, hashing, raw decoding or storage flushes.
The report fixture also does not compose native child retirement; that remains
an independent production collection prerequisite and a separate model/runtime
bridge. The [complete-report design](../../../docs/design-notes/distributed-final-results.md)
records the exact formats and implementation evidence still required.
