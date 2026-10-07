# Current handoff

This edition records the registered-runtime integration through `7178cf937` on
October 6, 2026. The isolated `runtime/main-refresh` branch includes the approved
LSP and generation contracts and main at `3644b0790`. Component source, local
receipts and hosted state were checked for this edition. Runtime assembly and
separate-host acceptance remain in progress.

The previous edition's statement that no authorized SSH destination was available
is obsolete. Linux component tests have run on the supplied test VM. Those tests
used an earlier source snapshot plus seven portability fixes; they do not prove
the two requested physical owner/executor placements on the current candidate.
The foundation codecs, registry, helper credits and owner generation DAL are also
implemented now. Their presence does not enable ordinary registered sessions.

## Where the tree is

[PR #819](https://github.com/Roasbeef/loom/pull/819) remains open and draft at
`b3bc47efdb2be7df421287aa437debdd034af9e5`, with no hosted checks on that head.
[Issue #697](https://github.com/Roasbeef/loom/issues/697) remains open. The local
integration work has not been pushed; publication and merge remain unauthorized.
Main has since advanced to `8facdb0ea`, whose
[CI run passed](https://github.com/Roasbeef/loom/actions/runs/37565157383).
That render/transfer optimization series is not yet integrated into this branch.

| Boundary | Current integration state |
| --- | --- |
| Owner custody and semantic transport | Original inputs, results, finite TLS BEAM controls, native forwarding and semantic workspace consumers are implemented. |
| Compile and Launch | Immutable Original/UnusedImportRewrite attempts, consumed streams and exact-helper retirement compose in component controls. Default registered assembly remains pending. |
| Helper consumption | `87fc9c35d` adds bounded input/output consumption credits and current-version wire decoding. |
| Generation history | `0e06673d6` and `cc668b1f2` retain bounded node claims, publication fences and retirement metadata. `cce28b4af` retains original owner generations and atomic child/system links. Actual physical join validation remains an assembly obligation. |
| LSP | `e6f30de42` and `bc0f9b25b` retain original custody and generated SQL. `c75dd49b9` and `7178cf937` add reviewed bounded parsing and consumed transport/state. Physical native and ordinary assembly joins remain pending. |
| Deployment | `a58713277` and `45de677f` commit reviewed strict owner/executor loaders and their manifest. Shipped role bootstrap, admin transport, full host activation and ordinary daemon assembly remain unbuilt. |
| Launch utilities | `ed4abd587` supplies named private role bundles, selected export, lifecycle commands and a setup guide. Current images deliberately lack runtime capability labels and cannot pass its startup gate. |
| Distributed orchestration | Executor pools, C1 ownership, C2 routing, C3 durable cross-node messaging and M1 controlled movement remain required. |

The [integration guide](design-notes/distributed-runtime-integration.md) records
full acceptance criteria. The [setup guide](distributed-setup.md) distinguishes
prepared bundles, packaged role support and actual physical execution. Earlier
review records describe their stated source revisions, not the entire current
candidate.

## Verification and its limits

The committed helper-credit integration passed broker with 458 tests, executor
with 400, code mode with 483 and client with 3,130. The owner-generation DAL then
passed storage with 253 tests. The client gate retains fifteen explicit optional
skips: one Linux `/proc` witness, thirteen shipped-server controls and one
rust-analyzer control. Formatting, affected lint and documentation checks passed;
the latest integrated documentation receipt has zero errors and 195 warnings.

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
Root core and LSP gates each pass all 211 tests; affected lint reports zero
errors. Executor/code-mode verification against this final combined source is
in progress. An extra large-array JavaScript probe
exposes the same existing sibling-recursion stack limit in both parser profiles;
no exact-limit JavaScript runtime success is claimed.

Full repository gates, actual shipped registered tools, both physical-host
placements, container execution and hosted CI have not passed on this candidate.

## What to do next

1. Finish the current integration wave for **#697**: complete the executor and
   code-mode checks against the committed deployment and consumed-LSP changes.
   Core, LSP and client checks pass. **Exit:** affected combined gates pass
   with the short scratch prerequisite, and every verified finding is resolved.
   Preserve ordinary local transport behavior and every existing test.
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
4. Integrate current main, run applicable model and full repository gates, and
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

## Deliberately open

The approved [LSP contract](../protocol-change/076-registered-lsp.md) and
[administration contract](../protocol-change/077-registered-generations.md) define
required implementation work. Full activation, original physical retirement and
normal daemon assembly are unbuilt, not accepted limitations of the final
feature. C1-C3 and M1 also remain required by **#697**.

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
