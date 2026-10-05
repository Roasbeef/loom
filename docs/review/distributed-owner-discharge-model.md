# Owner-run discharge contract model

This additive P model checks the owner-discharge prerequisite for #697. The
production component is frozen at the 22-file manifest
`/private/tmp/loom-distributed-wave2/owner-discharge-source-hashes.json`.
No production files or the earlier component review were edited for this model.
The manifest SHA-256 is `1e4fa3223b4bf730b14d6034560d036e16df3a6f68d09c93e97bf67bc4b71de7`; the separate
`owner-discharge-model-code-bridge.json` retains all 22 file hashes, prior model
source hashes and the unchanged 90 case/37 mutation definitions. The load-bearing
production sources are `owner_custody.gleam`
(`e18bbcb61956fa2261d30e9464d136f53156b8560eb13ab358702a52a386590e`) and
`custodian.gleam`
(`a440fc3dd280467e641b39b950aad3115207dc6a046b19df0e032c73a1a8e3fb`).
The prior 90 cases and 37 mutations remain; eight normal cases, eight exact
positive probes and nine additional mutations check the new boundary.

## Model and source bridge

`PSrc/OwnerDischarge.p` owns durable rows, volatile live disposition and pinned
incarnation in `RunCustodian`; `RunDownstream` owns independently accepted child
custody and retained exact late receipts. `PSpec/OwnerDischargeSafety.p` retains
its own commit, start, drain, unresolved, release and receipt histories.
`PTst/OwnerDischargeScenarios.p` advances only after actual actor replies.
`OwnerDischargeReachability` requires those independently observed histories
before reaching its exact positive assertion. It does not trust scenario stages.

| Model decision | Frozen production path | Complementary executable witness |
| --- | --- | --- |
| Atomic Fresh row is Unreleased before worker start. | `storage/owner_custody.admit_fresh` line 416; named `InsertOwnerTool`; `custodian.begin` line 862 commits before `start_relayed`. | Storage Fresh/pre-spawn reopen; owner crash/worker controls. |
| Only exact final commit followed by same-incarnation drain releases. | `custodian.report_held` lines 985/1029; `owner_custody.discharge` line 534 and `DischargeOwnerRun`. | Exact-byte mismatch, final/pre-drain reopen, normal finish/drain capacity reuse. |
| Loss, fatal and failed commits remain unresolved. | `custodian.unresolved` line 1078; `FenceRun` handler line 840; `answer_once` line 1058 preserves prior disposition. | Real held `call.try_call` plus killed worker; fatal followed by normal outcome; deferred-FK COMMIT failure. |
| Boot with any Unreleased row admits history only. | Initializer line 313; `owner_custody.unreleased` line 519; partial `owner_tool_run_custody` index. | Owner restart remains fenced; exact historical outcome and late receipt remain readable. |
| Collection preserves marker and requires Released. | `owner_custody.collection_ready` line 1671; named `FreezeOwnerTool`. | Early collection refusal and frozen Released marker. |
| Old runner cannot resolve a replacement actor. | Private `Pinned(Subject(Message))` destination line 81; runner construction line 323; `ask` line 723. | Captured original runner handle refuses after custodian restart. |
| Owner death cancels its relayed run. | `weft.cancel_when_exits(owner_pid)` line 896 and existing linked relay. | Production owner-kill witness; explicit guard mutant survives because relay death already cancels. This cancellation mechanism is assumed, not proved by the P model. |

Final payload integers stand for exact encoded outcome bytes. A journal COMMIT is
an atomic abstract durable operation, and an injected failed COMMIT changes no
row. COMMIT status, final-report provenance and original AllDelivered are trusted
runtime facts. One worker has at most one ordinary final outcome. Private pinned
incarnation models the original Subject/PID; it is not a wire capability or a
numeric token supplied by an untrusted runner. The model checks the owner/store
ordering and guards under these assumptions. The downstream actor retains late
receipt evidence independently; production commits that evidence through the
restarted custodian into its child row. That child-row codec/COMMIT/readback
bridge is covered by the production witness, not modeled as a second SQL store
here. Thus the model proves late evidence can survive worker/owner loss, not
that its own downstream readback implements the custodian child-table API. It is not a SQLite durability,
BEAM death, weft delivery or end-to-end refinement proof.

## Reachable controls and mutation evidence

Eight finite scripts cover happy same-incarnation reuse plus early collection;
Fresh/pre-start and final/pre-drain crashes; accepted downstream work plus worker
loss, restart, late exact receipt readback and stale pinned refusal; fatal followed
by ordinary exact final; failed final COMMIT; failed discharge COMMIT; and failed
Fresh COMMIT followed by genuine success. Each positive probe must produce its
registered historical assertion. The safety monitor verifies Fresh custody at
commit, exact successful commit bytes, same-incarnation drain, sticky unresolved
disposition, durable restart, collection authority and pinned child forwarding.

Nine mutants change real state/effect decisions with unchanged monitors: omitted
Fresh marker, release on final before drain, reopened startup, fatal overwrite,
early collection, ignored final COMMIT failure, ignored discharge COMMIT failure,
pinned rebinding and changed committed final bytes. Each selected original must
pass all requested schedules, then the mutant must compile and fail the intended
assertion. These are executable counterexamples, not assertions injected by a
scenario to manufacture the failure.

There are two logical tool keys, one live slot, one independent downstream actor,
two incarnations, one accepted origin and one rejected origin. Every script has
finite traffic and at most 11 owner operations. Reliable finite-script progress
is checked; there is no liveness claim under unbounded partition or unresolved
work. Old-format refusal and physical native work remain outside this model.

## Verification

The existing strict runner supplies isolated snapshots, actual child exit codes,
exact assertion validation, source hashes, scheduling-point statistics and replay
schedules. Defaults remain 1,000 safety schedules, 2,000 probe schedules, 100
mutation-control schedules and seed 697; checker limits remain 1,000 steps,
60 seconds, 65 seconds outer and 1 GiB. The baseline strict gate compiles without warnings and validates all 47 normal
cases at 1,000 schedules each and all 59 probes at their exact registered
assertions. The eight added normal cases use 24–52 scheduling points. Baseline
peak observed RSS is 318,799,872 bytes (about 304 MiB). All nine new mutants
compile and fail their intended independent assertions in the strict run.
The complete local `check.sh` gate exited 0 in 510.13 seconds: all 106 cases
validated and all 46 mutants compiled and failed their exact intended assertions
after controls explored 100 schedules each. All 48 P compiler invocations
succeeded. The maximum observed RSS across compiler/checker invocations was
318,799,872 bytes; no optional case was skipped. Actual P exits, measurement
exits, scheduling points, source snapshots and replay traces are retained in
`owner-discharge-model-final-verification.json` and its two referenced results
files. This is local bounded model validation; hosted CI and system acceptance
are separate.

Fresh independent Astra review found no actionable findings, with high confidence
within the stated bounded abstraction. It checked independent commit/drain/fatal
histories, DirectedProgress and exact probe nonvacuity, actual-decision mutation
sites, the frozen production bridge and the downstream/child-table distinction.
It did not rerun the gate or verify its eventual overall exit. No source changes
were requested or made. The initial sandboxed compile itself succeeded, but the
macOS RSS wrapper was denied `kern.clockrate`; the strict gate rejected that
wrapper failure. An explicitly permissioned retry measures actual P exit and
RSS separately, with no weakened bounds or assertion checks.

Native command retirement, resource cleanup, executor TLS authentication, actual
codecs, OS effect prevention and separate-host ordinary-tool/code-mode acceptance
remain outside this contract. Client gate results and their optional skips remain
separate evidence in the component review.

The root independently checked the exact copied model source on the integration
branch. All eight new normal cases passed 1,000 schedules each, and all eight
positive probes reached their exact assertions (runner exit 0, 19.894 seconds).
The nine new mutation controls passed 100 schedules each; every mutant compiled
and failed its intended assertion (runner exit 0, 237.229 seconds). This focused
integration replay does not claim to rerun the worker's full 106-case/46-mutation
gate or its RSS measurement. Exact commands, exits and logs are retained in
`/private/tmp/loom-distributed-wave2/owner-discharge-root-model-results.json`.
