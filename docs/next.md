# Current handoff

This edition records the registered-runtime integration through `55bc1f61` on
October 7, 2026. The isolated `runtime/main-refresh` branch includes approved
protocols 076 and 077 and main at `3ffb0bf52`. Source, local gate receipts and
hosted PR/main state were checked for this edition. Runtime assembly and
separate-host acceptance remain in progress.

The previous edition left native LSP transport and registry startup custody
unimplemented. Both components are now integrated and verified below. Native/workspace/resource live journal startup is also integrated. Owned LSP
startup/recovery and ordinary registered assembly remain open. A Launch readiness timeout during those checks
remains unresolved despite a passing diagnostic retry. The managed endpoint is
now implemented. The original owner custodian is wired through its generation DAL,
and the registry retains complete original generation plans atomically with first
admission. Restricted recovered journal owners now acquire managed custody before
opening SQLite. The permanent registry now parks under its actual parent before
opening SQLite and retains acquired connection custody before setup. These components do not by themselves enable ordinary registered
sessions.

## Where the tree is

[PR #819](https://github.com/Roasbeef/loom/pull/819) remains open and draft at
`b3bc47efdb2be7df421287aa437debdd034af9e5`, with no hosted checks on that head.
[Issue #697](https://github.com/Roasbeef/loom/issues/697) remains open. The local
integration work has not been pushed; publication and merge remain unauthorized.
The integrated main commit `3ffb0bf52` has a
[passing CI run](https://github.com/Roasbeef/loom/actions/runs/37580150259).
That status belongs to main, not this unpublished integration candidate.

| Boundary | Current integration state |
| --- | --- |
| Owner custody and semantic transport | `f320f6c5b` wires registered admission, historical reopen and receipt readback to the original actor/connection/path. Original inputs, results, finite TLS BEAM controls, native forwarding and semantic consumers are implemented. Default daemon construction remains pending. |
| Compile and Launch | Immutable Original/UnusedImportRewrite attempts, consumed streams and exact-helper retirement compose in component controls. Default registered assembly remains pending. |
| Managed endpoint | `5733967e9` binds publication and removal to the original registry writer, concrete services and endpoint lifetime. It retains bounded digest receipts without restoring lost credits. Actual physical retirement and full scope administration remain pending. |
| Helper consumption | `87fc9c35d` adds bounded input/output consumption credits and current-version wire decoding. |
| Generation history | `3ade15ea9` and `77b3b217` add permanent original provenance. `40169105` adds restricted managed recovery of native, workspace and resource journals, with explicit close and original normal-exit evidence. Actual physical join validation and bounded history transport remain assembly obligations. |
| LSP | `e6f30de42` and `bc0f9b25b` retain original custody and generated SQL. `c75dd49b9` and `7178cf937` add reviewed bounded parsing and consumed transport/state. `7d256b402` and `e336f4a19` add original first-placement native custody and credited ServerLease transport, including actual Linux FullEnforcement controls. Owned LSP journal startup, finite collection, semantic/result retirement and ordinary assembly remain pending. |
| Deployment | `a58713277` and `45de677f` commit reviewed strict owner/executor loaders and their manifest. Shipped role bootstrap, admin transport, full host activation and ordinary daemon assembly remain unbuilt. |
| Launch utilities | `ed4abd587` supplies named private role bundles, selected export, lifecycle commands and a setup guide. Current images deliberately lack runtime capability labels and cannot pass its startup gate. |
| Distributed orchestration | Executor pools, C1 ownership, C2 routing, C3 durable cross-node messaging and M1 controlled movement remain required. |

The [integration guide](design-notes/distributed-runtime-integration.md) records
full acceptance criteria. The [setup guide](distributed-setup.md) distinguishes
prepared bundles, packaged role support and actual physical execution. Earlier
review records describe their stated source revisions, not the entire current
candidate.

## Verification and its limits

The corrected live-journal integration at `55bc1f61` passes all 501 executor
tests in 202.25 seconds, 220.15 seconds including build, with the command's own
exit zero. Formatting, executor lint, documentation and prelude checks pass;
all six imported hashes remain unchanged. Independent review found one low
compatibility issue: legacy native poison replies moved before rollback/close.
The fix restores that ordering only for legacy custody and preserves the owned
close-observation sequence. Both focused suites then pass: 17 native journal
and 13 owned-live controls. The earlier worker full gate passed 473 tests before
this small fix; the integrated gate is the full corrected-candidate receipt.
Twelve compiled runtime mutants fail original link, checked close, Normal-DOWN
or resource-binding assertions. Actual parent death still provides best-effort
cleanup, not ordered physical retirement.

The native LSP integration at `e336f4a19` passes all 488 executor tests and 461
broker tests, plus the helper gate. Each command's own exit is zero; executor
elapsed time is 195.32 seconds including build and 174.22 seconds for tests.
Formatting, affected lint, documentation and prelude checks pass. All 25 imported
hashes remain unchanged; only the executor document mirrors required composition
with the earlier registry/history documentation.

Independent review found one reachable cancellation-signal leak on successful
input/output completion. The correction releases each original signal at
AllDelivered and preserves the output-to-original-execution join. Three actual
Service credit cycles observe the exact original signal PIDs terminate; compiled
input and output no-cancel mutants fail that assertion. The bounded independent
recheck is clean. An earlier component run had three Launch failures because its
Erlang fixture matched the old private Service state tuple. Updating only those
three patterns for the added LSP row field restored the unchanged ten Launch
controls and the component's full 435-test gate. Their assertions and deadlines
were not changed; the earlier failed receipt remains preserved.

On Linux, both real-helper controls pass under a dedicated delegated user cgroup:
initialize/hover plus graceful client stop, and separately an actual native
Completed/ProtocolComplete terminal before local closure. The latter asserts
FullEnforcement, code zero, no cancellation, timeout or truncation. Both independently
observe original native retirement and managed drain while the DAL lease remains
unretired. The source was the reviewed component base `f2dea5c38` plus its exact
25-file overlay, archive SHA-256
`eaf380fcadde98cc8ccec434f8749308d1137be8c9d89133eadc5a069202b0b7`;
all overlay hashes matched again after testing. This establishes the Linux native
component, not an assembled owner on one machine driving the other machine's
executor or final same-candidate acceptance in both placements.

The permanent-registry startup integration at `ee8ab8ae` passes all 475
executor tests; the command's own exit is zero, with 186.97 seconds including
build and 170.90 seconds of tests. Formatting, executor lint, documentation and
prelude checks also exit zero, and all four imported hashes remain unchanged.
Independent review found no actionable issue. The resource-free linked writer
acknowledges its original parent before typed initialization; acquired connection
custody is installed before shared SQL setup runs. A queued parent exit does not
preempt an already admitted setup turn. Failed close retains the actual connection
and cannot supply successful release. This fixes registry construction, not full
host activation or physical retirement.

The owned-history integration passes all 460 executor tests in 182.70 seconds,
including build time. Formatting, executor lint, documentation and prelude checks
exit zero; all six imported file hashes remain unchanged. Independent review found
no production defect and two test gaps, both corrected before integration: worker
death is observed before attempted adoption, and real SQLite writer locks remain
held until the original recovery reaches failed-setup cleanup. Fifteen focused
controls pass; ten executed mutants fail their intended assertions. The worker
full gate separately passed all 444 tests on its older component base. These
results establish restricted recovery and original handle release, not live Fresh
startup, generation transport or complete physical retirement.

The provenance integration passes all 445 executor tests in 165.46 seconds,
including build time. Normal SQL regeneration, executor lint, documentation and
prelude checks exit zero; all fourteen reviewed file hashes remain unchanged.
Independent review found no actionable issue. Sixteen new real-SQLite controls
cover atomic parent/plan admission, exact retained metadata, permanent quota
charges, migration and corruption refusal. Four removed-check mutants fail their
intended runtime assertions. Migration interruption after each DDL statement and
power loss were not separately injected; rollback evidence there is the explicit
transaction and error flow.

The worker's full-suite log reported 445 passing tests but its original runner
exit could not be recovered. That receipt remains uncertified. The separately
executed integration gate above captured its own zero exit and complete gate
footer; no product failure cause is inferred from the missing worker receipt.

The endpoint milestone passed all 429 executor tests, all ten focused
Launch controls and all 866 web-view tests. The subsequent owner-custodian
integration passed all 3,147 client tests in 428.67 seconds including build time,
with the same fifteen explicit optional exclusions described below. All nine new
registered actor/SQLite controls ran. Independent owner-custodian review is clean. The full executor command exited zero
in 171.75 seconds, including build time. Changed-source formatting, executor and
client lint, documentation checking and the prelude gate pass. The latest
documentation receipt has zero errors and 194 warnings. Independent endpoint
review found no actionable issue; two removed-check mutants separately failed
the intended original-writer and absent-row assertions before source restoration.

An earlier post-rebase Launch run passed nine controls and failed its unused-import
Compile/Launch control because the owner expired waiting for executor readiness.
The executor output was lost when the owner failed before consuming the managed
report. `f055709f0` persists returned role results without changing their Result,
deadlines, assertions or lifecycle. The single diagnostic retry and subsequent
full Launch module pass. The original cause remains unknown; those passing runs
are not a startup fix. The original failed artifacts are retained.

The owner worker's first full gate after its path-binding fix timed out in an
existing code-mode build control. The unchanged control passed alone, the
unchanged candidate then passed its full worker gate, and the integrated gate
passed above. The timeout cause remains unproved; no deadline or exclusion was
changed to obtain these results.

The remaining receipts in this section predate the latest main rebase. They
establish component coverage at their stated source revisions, not a full gate
on the current candidate.

The committed helper-credit integration passed broker with 458 tests, executor
with 400, code mode with 483 and client with 3,130. The owner-generation DAL then
passed storage with 253 tests. The client gate retains fifteen explicit optional
skips: one Linux `/proc` witness, thirteen shipped-server controls and one
rust-analyzer control. Formatting, affected lint and documentation checks passed;
that documentation receipt had zero errors and 195 warnings.

Adding the LSP custody DAL exposed a recurring Launch shutdown failure in the
combined executor gate: 411 passed and one failed because a node logged
`weft_drain_proof_lost`. A deterministic regression reproduced it against the old
source. Channel shutdown could stop paused leaves before the asynchronous weft
scope adopted them. `832f86095` queues cancellation through the original witnessed
scope and accepts only its normal exit as transport join. Native retirement and
resource cleanup retain separate witnesses; independent source review is clean.

The first independent combined rerun then passed 414 tests and failed a separate
parked-reservation fixture. That fixture expected its callback to notify completion
after cancellation could kill it. Production instead admits the reservation to an
independent custodian writer. `6b26739e` corrects the fixture: the exact callback
must die before releasing the original SQLite writer, and reopening proves its
COMMIT. Existing uncertain/no-submission/cleanup assertions and timeouts remain.
Independent review is clean. The combined executor gate with deployment imported
passes all 422 tests, with the required short scratch path, in 149.48 seconds.

The Linux test host ran the executor suite on `cc668b1f2` plus seven portability
fixture patches, all 384 tests passing. Those patches are committed locally as
`c1754adae`. They select the host's temporary directory, account for OTP 29's
64-MiB JIT mapping in compiler fixture file-size limits, and retain a test clock
until shutdown joins. The Linux sandbox self-test and offline code-mode control
also passed. This was component validation on Linux, not a remote owner driving
the other machine's executor. Both physical placements still need the assembled
runtime and the same exact candidate revision.

All 23 imported launch-tooling tests pass. Independent review found and verified
corrections for canonical mount targets and an unresolved marker in the shipped
membership fragment; its bounded recheck is clean. Docker lifecycle calls in
these tests are mocked. One test generates and checks real local certificates;
it does not establish a live TLS deployment.

The deployment slice passes six owner and seven executor focused controls.
Independent review found no blocking source issue. Its isolated full package runs
omitted the required short scratch root and refused existing Launch fixture
enrollment before effects; those red receipts remain. The corrected integrated
executor gate passes above. The integrated client gate passes all 3,136 tests in 436.55 seconds, retaining
the fifteen explicit optional skips listed above.

The consumed-LSP slice passes 211 LSP tests and 211 core tests, including existing
JavaScript controls. Independent review found a retained-integer accounting gap:
Registered diagnostic coordinates and versions had fixed charges without finite
numeric ranges. The correction checks LSP unsigned/signed integer ranges before
retention, settlement or consumption acknowledgement. Its bounded recheck is
clean; Standard transport behavior stays unchanged. Integration updates two local
transport test patterns to assert their existing ordinary variant explicitly.
Root core and LSP gates each passed all 211 tests; affected lint reported zero
errors. The combined pre-rebase executor and code-mode checks subsequently passed
all 422 and 483 tests respectively. An extra large-array JavaScript probe
exposes the same existing sibling-recursion stack limit in both parser profiles;
no exact-limit JavaScript runtime success is claimed.

Full repository gates, actual shipped registered tools, both physical-host
placements, container execution and hosted CI have not passed on this candidate.

## What to do next

1. Finish owned LSP startup/recovery for **#697**. Native LSP transport,
   parent-owned registry startup and all three live service journals are integrated. **Exit:** exact source passes meaningful failure
   controls, full affected package gates, independent review and integrated
   verification. Durable generation provenance and restricted managed recovery
   are integrated. LSP startup still needs its original parent-owned Fresh handle and restricted
   recovery; the other three service journals and registry have that construction. Preserve every existing test and ordinary
   local behavior; earlier worker receipts do not certify later fixes.
2. Build the approved ordinary registered path from protocols 076 and 077.
   Preserve one original owner Broker/custodian, exact-generation publication,
   executor-only physical paths, full reports, jobs, hooks, cwd, guidance, Git and
   LSP. **Exit:** default tools and code mode run with the checkout absent from
   the owner, and Close/restore retains original history and permits only proved
   clean successors. Historical query alone does not establish fresh execution.
3. Complete role packaging and the two physical-host placements, followed by
   executor pools and C1-C3/M1. **Exit:** the same candidate passes normal effects,
   cancellation, partition, restart, lost-reply, routing, durable messaging and
   controlled-movement controls. Automatic failover and workspace snapshot
   migration remain deferred.
4. Check for later main changes, run applicable model and full repository gates, and
   review the assembled system. **Exit:** exact candidate evidence closes the
   integration checklist before publication or merge is requested.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and record the
reopening where the ruling lives.

**Executors share the runtime trust domain.** Trusted TLS BEAM membership carries
physical service traffic. Satellites remain jailed and distribution-disabled;
executor membership grants no Raft vote. See the
[integration guide](design-notes/distributed-runtime-integration.md).

**Compile has two fixed attempts.** Approved
[protocol 071](../protocol-change/071-remote-compile-attempts.md) permits Original
and one deterministic UnusedImportRewrite under the same authority and deadline.
It grants no retry framework, renewed budget or replacement grants.

**Launch retires its exact borrowed helper.** The
[protocol-067 addendum](../protocol-change/067-remote-workspace-services.md#addendum-exact-original-helper-retirement-for-launch)
costs one helper restart per Launch while preserving ordinary command/Compile
reuse. It never shuts down the shared pool for each Launch.

**Cleanup witnesses remain separate.** Native retirement, transport join,
capability drain, resource removal and complete-report COMMIT discharge distinct
obligations. Terminal history, actor death, absence and receipt cannot replace
another boundary's witness. See the
[retirement architecture](architecture/launch-native-retirement.md).

**Generation policy is approved.**
[Protocol 077](../protocol-change/077-registered-generations.md) selects sixteen
live/unretired slots, 4,096 permanent identities and 256 MiB of logical metadata.
Original removal acknowledgement and durable Removed precede slot reuse.
Uncertain custody stays charged. Successors retain immutable original owner
and system-child links; history reads and receipts cannot repeat an effect.

**Workspace native commands retain their semantic parent.** The approved
[protocol-077 addendum](../protocol-change/077-registered-generations.md#addendum-native-identity-beneath-a-workspace-request)
uses a distinct deterministic identity beneath the exact retained Workspace or
system semantic request. It preserves the original quota group and adds no
system ordinal. Admitted capabilities retain their existing purpose pair.
Standalone native system commands separately reserve original identity before
Broker clearance and admit exact cleared bytes afterward. These identity and
sequencing changes are approved directions; their production wiring remains
unimplemented. Initialize does not imply an invented native setup command.

## Deliberately open

The approved [LSP contract](../protocol-change/076-registered-lsp.md) and
[administration contract](../protocol-change/077-registered-generations.md) define
required implementation work. Full activation, original physical retirement and
normal daemon assembly are unbuilt, not accepted limitations of the final
feature. Durable original journal/enrollment provenance and restricted managed
recovery of native, workspace and resource writers are integrated. The next
assembly prerequisite is original LSP live startup and restricted recovery,
followed by the sole scope administrator and authenticated bounded history
transport. C1-C3 and M1 also remain required by **#697**.

The owner accepted inherited workspace/cache filesystem policy without an
aggregate disk quota. New LSP transport and retained-state inventories keep their
explicit bounds. Automatic failover and workspace snapshot migration remain
deferred. None of these is unfinished work somebody forgot.

## How to verify

Use `make check-<package>` for affected packages, `make fmt-check`, affected lint,
`make doc-check` and `make prelude-check`, then `make check` for the complete
candidate. Regenerate the normal offline seed when its source/compiler changes.
Capture each command's own exit status.

**Use short, isolated socket scratch paths.** Checkout-backed tests stay outside
`/tmp`, which the jail replaces. Set `LOOM_TEST_SCRATCH` explicitly for deep
worktrees; an enrollment refusal before effects is not evidence of a runtime
regression.

**Serialize builds that share generated artifacts.** Parallel package gates in
one checkout can collide while packaging the TUI or helper. Keep independent
worktrees isolated and preserve failed receipts. Investigate a concrete failure
before changing a timeout or calling it a flake. See
[execution](execution.md) for the remaining rules.
