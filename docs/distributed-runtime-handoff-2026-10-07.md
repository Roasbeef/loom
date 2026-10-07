# Distributed runtime: October 7 handoff

Implementation is paused at the owner's request. This document is the restart
record for [issue #697](https://github.com/Roasbeef/loom/issues/697) and
[draft PR #819](https://github.com/Roasbeef/loom/pull/819). It is separate from
`docs/next.md` so a new session can recover the detailed state without relying on
conversation history or temporary reports.

The integration code baseline is `1c50b074fbde0b2b43a50689d3272798b90c59b7`, on
`runtime/main-refresh`. It contains 309 commits above integrated main
`142eba4a3b0dca245993851b893e7479c70d50c7`. The October 7 preservation commits on
component branches are archival snapshots, not additional integrated features.
The final commits after this baseline contain this handoff and its evidence.

**The distributed product is unfinished.** Substantial execution, custody,
transport and lifecycle components exist and have component evidence. Ordinary
registered daemon startup, enclosing physical retirement, shipped role activation,
both physical-host placements, executor pools and C1-C3/M1 remain required. The
full repository gate is red. No merge or production rollout is authorized.

## 1. Resume here

Use this checkout:

```text
/Users/roasbeef/gocode/src/github.com/roasbeef/loom/.worktrees/runtime-main-refresh
```

The primary checkout remains on `docs/code-mode-saved-programs` and contains
unrelated untracked files. Its contents were left alone. Do not treat that
checkout as the integration candidate.

`origin/runtime/main-refresh` and the PR branch,
`origin/codex/distributed-runtime-integration`, carry the integrated checkpoint.
The PR's prior head, `b3bc47efdb2be7df421287aa437debdd034af9e5`, is preserved on
`origin/runtime/pre-refresh-oct7`. Updating the PR used an exact lease against
that prior head. The PR remains draft.

The older local `.worktrees/distributed-runtime-design` checkout still holds
pre-rebase tip `a5744217f`, preserved remotely as
`runtime/pre-main-refresh-oct7`. Its unrelated untracked
`packages/client/test/owner_binding_runner.gleam` was left alone. Its local
`codex/distributed-runtime-integration` branch therefore differs from the
updated remote PR branch. Do not push that old local ref over the refreshed PR.

The two unfinished source branches are:

| Branch | Checkpoint | Original base | Meaning |
| --- | --- | --- | --- |
| `runtime/source-acquisition` | `3d76f2db816b8e72530d85ab7f07ad2d0765ad9c` | `ddec0465b` | Indexed original-intent lookup and registered hook acquisition. One known production defect; new acquisition controls have not run. |
| `runtime/compile-preparation-custody` | `1676ef1ac50b5ed658276216d005359c4bd88075` | `5230b75d4` | Physical Compile preparation owner and release custody. Partial controls pass; aggregate delivery is blocked on an unapproved weft API. |

Their worktrees are `.worktrees/registered-source-acquisition` and
`.worktrees/compile-preparation-custody`, under the repository root. Neither
checkpoint was merged into the integration candidate. Start by inspecting the
single checkpoint diff against its stated base. Do not merge its entire old
history into the refreshed branch.

The [branch inventory](review/distributed-runtime-handoff-2026-10-07/branch-inventory.json)
records all 39 preserved draft branches, original bases, resulting commit IDs,
local paths and per-file SHA-256 hashes. Thirty-seven are historical component
snapshots; most have reviewed successors already in the integration history.
Their archival commits preserve exact old bytes, including stale documentation
and intermediate implementation choices. They are not a queue of 37 patches to
cherry-pick. Generated SQL and manifest files were committed separately where
present. No component gate was rerun merely to archive an old draft.

All implementation workers were frozen. No worker command was left running at
the pause. No tracked source was edited after the final source-acquisition
snapshot. Hosted CI may start from the push; inspect the exact PR head before
using any hosted result.

## 2. Why the work took so long

There was real engineering difficulty here: an observed outcome, durable COMMIT,
physical process retirement and permission to reuse a resource are different
facts. Crossing hosts exposes lost replies and original-writer ownership that a
single-process path can hide. The original authority, finite deadline and
resource owner must survive observation failures without granting a repeated
effect. Work that established those boundaries was necessary.

The execution strategy also created avoidable delay. We built and reviewed many
prerequisites before demonstrating one ordinary owner-to-executor path. Every new
component exposed another enclosing ownership requirement, and the next component
became the immediate target. The result was a large body of individually tested
code while the shipped daemon still rejected registered selection. A short,
explicit dependency chain to the first working daemon path would have exposed
that integration gap earlier.

The least useful rabbit holes were these:

- **Expanding future design while the first path was blocked.** Detailed C3
  outbox limits, history APIs and physical-close proposals are useful decisions,
  but designing them during hook and startup integration did not make the first
  ordinary remote session run. The proposals are preserved; they should not
  become another round of general design before a concrete caller needs them.
- **Trying to adapt synchronous polling to an asynchronous delivery protocol.**
  Compile preparation used `pull(within: 0)` and lost later replies in the
  actor's catch-all. Unlinking then broke the original caller-exit behavior.
  These experiments found real constraints, but once the typed selector was
  known to be missing, further work on that adapter had low value. Stop at the
  missing primitive instead of compensating with polling or extra ownership
  machinery.
- **Repeating large validation runs while assembly was still moving.** The
  model and full-client runs provided valuable evidence, but some broad reruns
  occurred before the default production construction was stable. The strict
  remote model gate alone took about 35 minutes, and a shipped client run took
  about nine and a half minutes. Run focused controls after local edits and
  reserve the full matrix for a frozen integration candidate.
- **Carrying many frozen worktrees and temporary reports.** Thirty-nine dirty
  task worktrees remained at the pause. Importing, hashing, rechecking and
  reconstructing which version was authoritative consumed time. The integrated
  branch and one durable inventory should own current state; old worktrees
  should be treated as archives after their useful changes land.
- **Ordinary implementation and environment mistakes.** Wrong imports, fixture
  dependencies, receive ownership, PATH selection and sandbox restrictions
  caused real failed runs. They were corrected or recorded, but they should
  not have been allowed to look like progress on the product's acceptance path.

Some investigations were worth finishing. The catalogue migration had to preserve
both historical version-nine layouts. The hook construction had to bind Effects
to the original writer before any callback could execute. The shipped-tail test
really cancelled before output existed, and the source-acquisition test really
found an incorrect missing-row error. Those are concrete defects with reachable
callers. The problem was allowing every adjacent question to expand into another
workstream before reaching the ordinary daemon.

The next session should keep one next observable result: a normal registered
session starts, acquires its real hook sources and executes an ordinary remote
operation with no owner checkout. Preserve the required custody invariants, but
reject speculative mechanisms and unrelated cleanup. The later issue phases
remain required; they should follow the working path in dependency order.

## 3. Product contract and settled decisions

Read the [integration guide](design-notes/distributed-runtime-integration.md)
for the complete acceptance checklist, then the
[design](design-notes/distributed-runtime.md) and
[API plan](design-notes/distributed-runtime-api.md). Protocol
[078](../protocol-change/078-registered-lsp.md) and
[079](../protocol-change/079-registered-generations.md) are the current registered
contracts. Earlier component drafts may still refer to 076/077; main's rebase
required renumbering.

The owner holds the conversation SQLite store, approval authority, budgets and
owner custody. The executor holds the authoritative workspace, toolchains,
physical effects and physical journals. Trusted executors use TLS BEAM membership
in the runtime trust domain. Satellites remain jailed and distribution-disabled;
executor membership does not confer an ownership-service vote. Both physical
placements must work on the same candidate, with the checkout absent from the
owner.

These choices are already settled:

| Decision | Recorded behavior |
| --- | --- |
| Compile attempts | Original and one deterministic UnusedImportRewrite, with original authority and deadline. No general retry engine or renewed grants. Protocol 071. |
| Launch helper | Retire the exact borrowed helper for each Launch; preserve normal command/Compile reuse and the shared pool. Protocol 067 addendum. |
| Closure evidence | Native retirement, transport join, capability drain, actual resource removal and report COMMIT are distinct. History, absence or actor death cannot substitute for a required original witness. |
| Generation bounds | Sixteen live/unretired slots, 4,096 permanent identities, 256 MiB logical metadata. Actual removal ACK and durable Removed precede slot reuse. Uncertainty remains charged. Protocol 079. |
| Native semantic parent | Workspace/system requests retain distinct deterministic native identity beneath the original semantic operation, without inventing another system ordinal. |
| Hook acquisition | Preserve a pure fixed candidate outside the observer. Lookup hits permit historical observation only. Partial preparation cannot regain fresh authority. Preserve original bytes, IDs and deadlines. |
| Owner source size | The owner explicitly approved an 8-MiB accepted-text limit on October 7. It is checked after the read, so it does not bound peak read allocation or read time. |
| Hook inventory | Acquire the existing user/project/local set; explicit plugin documents preserve their source kind. No automatic plugin inventory or new trust CLI. |
| Filesystem policy | Inherit the existing workspace/cache policy without an aggregate disk quota. Explicit transport and retained-state bounds still apply. |
| Later scope | Executor pools, C1 ownership, C2 routing, C3 durable cross-node messaging and M1 controlled movement remain required. Automatic failover and workspace snapshot migration remain deferred. |

Publishing the checkpoint does not approve pending APIs, dependencies or policies.
The user authorized commit and push at the pause, not merge, deployment, new
remote-machine credentials or private-source transfer.

## 4. What is integrated

The integration branch contains original owner custody, retained inputs and
results, finite TLS BEAM transport, semantic workspace consumers and native
forwarding. Compile/Launch components retain fixed attempts, consumed streams,
complete reports and exact-helper retirement. Registered generation journals,
restricted recovery, registry ownership, helper credit and finite LSP components
are present. They still need the enclosing production composition.

The latest changes are a useful reading sequence:

| Commit | Change | Primary code |
| --- | --- | --- |
| `17cfe2403`, `e6aa65d68` | Rebase compatibility for typed workspaces, model profiles and both catalogue layouts. | `client/daemon`, `storage/catalogue`, catalogue migration tests. |
| `62c9b8ee7` | Registered goal/advisor checks retain original system work and publish GoalChanged. | `client/registered_system_work`, `client/goalcheck`, `client/advisor`. |
| `d84b60a91` | Registered hook callers use original custody and retained receipts. | `client/hookrunner`, `client/hookserve`, `client/hookwire`. |
| `8fcc52cc7` | Effects are constructed from the original writer before runtime startup. | `runtime/api`, `runtime/supervisor`, `runtime/fact_effects_test`. |
| `d698b5aea` | Original first-submit workspace system reads and retained observation. | `client/remote/workspace_binding`, `client/remote/workspace_client`. |
| `b2615b16c` | One prepared hook counter with acknowledged cleanup. | `client/hookserve`, registered hook construction controls. |
| `ddec0465b` | Accepted fixed source-acquisition and owner-size policy. | Protocol 079; implementation remains on its separate WIP branch. |
| `551dc3fc7` | Shipped-job test waits for the original job's staged bytes before kill. | `client/daemon_shipped_jobs_test`. |

Follow the module docs and package maps to the actual types. Do not infer
production availability from an exported component API. For example,
`packages/client/src/client/daemon/main.gleam` calls `serve.resolve_managed` and
`serve.assemble_in_domain`; `packages/client/src/client/serve.gleam` still refuses
`workspace.Registered` before entering the local resolver. The normal resolver
and assembly still own local workspace/helper/seed/toolchain decisions. The
ordinary hook path still loads local sources. Adding registered components
elsewhere has not changed that default route.

The [setup guide](distributed-setup.md) and `scripts/distributed` launch utilities
already describe named role bundles and lifecycle commands. The images lack the
runtime capability labels required by the launcher's startup gate. A bundle or
image build is not proof of shipped role support.

## 5. Unfinished hook-source acquisition

Checkpoint `3d76f2db8` owns eleven files: client/storage package maps and mirrors,
`storage/owner_custody`, its owner-generations tests, `client/remote/custodian`,
its registered tests, and new `client/remote/hook_source_acquisition`, acquisition
tests and `support/hook_source_beam_fixture`. It introduces no SQL schema, FFI,
package dependency, default `serve` wiring or new trust policy.

The intended flow is `capture_owner`, `fixed_batch_plan`, `acquire`, then bounded
`observe`. The fixed plan retains owner source bytes, original source IDs and
one absolute deadline outside the observer. Indexed metadata lookup distinguishes
absence from an existing exact association. Historical hits observe the retained
batch; they cannot mint fresh permission. The manifest and two source intents
consume three existing charged reservations. Source failures retain their
position in the original user/project/local set.

The first production defect is precise. `lookup_system_intent` passes the indexed
header result through the existing private `one` helper. That helper returns
`Invalid("expected exactly one owner custody row")` for both no rows and duplicate
rows. The new lookup requires no rows to be `Missing`; acquisition depends on
that result to prepare the original candidate. The failing test is
`indexed_intent_lookup_separates_missing_address_from_association_conflict_test`
in `packages/storage/test/storage/owner_generations_test.gleam`. Fix the empty
case at the new lookup boundary while preserving duplicate/corrupt-row refusal.
Do not relax the test or globally change `one` without auditing its callers.

The frozen validation state is:

| Observation | Result |
| --- | --- |
| Canonical client warning-free build | Exit 0, 8.98 seconds, before the final expiration checks. |
| Latest storage build | Exit 0, 1.36 seconds. |
| Latest owner-generations tests | 32 pass, 1 fail, 0 skip; wrapper exit 1. Test phase 1.90 seconds. |
| Final expiration checks | Written before `load_registered` and immediately before success, formatted; not subsequently compiled or tested. |
| Registered-custodian actor tests | Not run for this slice. |
| Seven new acquisition tests | Written, not run. |
| Mutants, full suite, static gates, independent implementation review | Not run for this slice. |

The final checks close a reachable observation gap: both remote reads can finish
before the deadline, but trust/parse work can finish after it. An outer observation
budget alone cannot permit an expired plan to become VerifiedSources. Test that
actual delayed tail before claiming the fix, and prove an omitted-final-check
mutant fails. The prose qualifies BEAM copying; no large-body allocation result
has yet been measured.

The remaining controls include lost preparation replies with the same external
candidate, equal concurrent candidates, cancellation before the next slot,
missing/unreadable/symlink/oversized/invalid-UTF8 remote sources, changed full
receipt association without ACK, admitted-only ACK recovery, maximum labels and
zero-write inventory failure, and measured body-copy retention. The seven draft
tests cover only part of this list. Full hook/trust/workspace regression and a
fresh independent implementation review remain necessary before import.

Original logs are `/private/tmp/registered-source-build-import-fix.log` and
`/private/tmp/registered-source-storage-lookup-fix.log`. Earlier failed build and
test inputs remain under `/private/tmp/registered-source-*`. They are diagnostic
local files; this document and the committed branch are the durable recovery
record.

## 6. Unfinished physical Compile custody

Checkpoint `1676ef1ac` preserves five files: executor package maps,
`executor/remote/compile_service`, new `compile_preparation`, and its tests. The
[interim report](review/distributed-runtime-handoff-2026-10-07/compile-preparation-interim-milestone.md)
contains its original hashes, exact controls and full limitations.

The physical owner pins the original caller, resource journal, complete input,
native service and canonical path. A one-use parked transition precedes exclusive
mkdir. Only an actually acquired directory may later be deleted. Partial layout
and possibly committed Ready retain their original owner. Native-close validation,
actual deletion, release COMMIT, exact readback and the original owner Normal
join are required before constructing a release proof. An absent path after
failed SQL is still uncertain custody.

Thirteen focused controls passed, along with three intended mutation failures,
warning-free compilation and the stated static gates on that frozen source.
Those controls did not run a successful compiler/helper artifact or prove the
whole original aggregate close. Four whole-close controls remain pending.

The blocker is a real protocol mismatch. `weft.pull(detached, within: 0)` leaves
demand outstanding. A later Delivered/Done reply can arrive between polls and be
discarded by the actor's catch-all. Keeping the original link and using the
existing trapped-exit selector fixes the independent caller-exit issue; it does
not supply typed asynchronous outbox delivery. The current polling code remains
a blocked draft and must not be imported as finished custody.

The proposed [typed Detached interface](review/distributed-runtime-handoff-2026-10-07/weft-detached-selector-proposal.md)
adds `select_detached`, `request_next` and `deselect_detached`, with original scope
monitoring kept separate. The owner has not approved this API or its exact
Loom dependency-pin update. Do not replace it with a Dynamic router, copied
library internals, polling relay or longer receive timeout.

## 7. Validation ledger

The [machine-readable receipts](review/distributed-runtime-handoff-2026-10-07/gate-receipts.json)
preserve selected actual command exits, elapsed time and original local log paths.
The receipts are not a claim that the final documentation commit reran those
commands. Formal runs and older component results are documented here and in the
existing review records at their actual revisions.

| Gate / revision | Actual result | Limit |
| --- | --- | --- |
| Full `make check`, `a1ab45a02` | Exit 2 after 34.97 seconds in Python self-tests. | Package/release matrix never reached. Full repository remains red. |
| P `make model-check`, `dedd107f6` | Exit 0, 196 expected outcomes, 572.17 seconds. | Bounded model evidence. |
| TLA+, `dedd107f6` | Exit 0, seven safety cases, forty intended violations, 148.24 seconds. | Bounded model evidence. |
| Lean, `a1ab45a02` | Twelve theorems and 684 production comparisons passed; relevant sources unchanged. | Selected admission correspondence, not full runtime proof. |
| Strict remote model, `d84b60a91` | Exit 0, 146 cases, 68 compile-clean mutation controls, 2,085.02 seconds. | Does not execute the assembled product. |
| Strict Launch model, `5d69aaefc` | Exit 0, 15 safety cases at 1,000 schedules each, 15 witnesses, 9 controls, 13 mutants; 423.12 seconds. | Same boundary. |
| Rebased storage | Exit 0, 274 tests. | Storage component, not full repository. |
| Goal integration, `62c9b8ee7` | Exit 0, 3,260 client tests. | Fifteen optional exclusions, including thirteen shipped-server controls. |
| Hook integration, `d84b60a91` | Exit 0, 3,276 client tests, 403.62 seconds including build. | Same fifteen optional exclusions. |
| Latest assembly components | 193 runtime, 14 registered workspace, 11 ordinary workspace, 13 binding, 6 construction and 14 legacy hook cases pass. | Focused integration checks; no default registered daemon. |
| Shipment, `6ab920d96` | Exit 0, 44.55 seconds. | Builds server; does not establish registered startup. |
| Full shipped client, `6ab920d96` | Exit 2, 3,295 pass and 1 fail, 568.64 seconds. | All thirteen shipped fixtures enabled. Only explicit exclusions are Linux `/proc` and rust-analyzer; EUnit reports zero skips. |
| Focused shipped-tail correction, `551dc3fc7` | Exit 0, 2.89-second test (3.73-second wrapper), client lint exit 0. | Full shipped-client rerun after correction remains pending. |
| Simulation seed 997 | Exit 2 on integration and clean main `142eba4a3`; four failures reproduced. | Existing harness ordering defect; not fixed. |
| Two physical-host directions, containers, full candidate CI | Not passed. | Required acceptance remains. |

The shipped-tail failure was a fixture ordering error. Its PID marker preceded
`exec tail`, and cancellation after 83 ms occurred before the helper emitted any
output. The test expected cursor `20:0`. The correction waits for exactly the
original job's 20 staged bytes, then requires the normal public nonblocking poll
to report running/pending and cursor `20:0` before kill. The eight provider
exchanges, 120-second original deadline, terminal content, cancellation and
lifetime assertions remain intact. Independent review found no weakening.

The first assembled concurrent workspace test assumed an observer could not
arrive before the winning submission. An early historical lookup can exhaust its
observation budget with the exact TransportUncertain result. The corrected test
then requires completion through the same plan before its unchanged absolute
deadline, and both callers must agree on the canonical receipt/ACK with one
original UUID, child, ordinal and physical read. Production transport was not
changed.

For model ordering, the first failing `tcCompileReadySubmitUnassociated` trace
was overwritten. Its cause cannot be asserted retrospectively. A separately
retained seed-698 trace proved a callback arriving after association release; the
fixture now waits for the existing held-callback event and retains all assertions.
Do not claim the retained trace explains an unavailable earlier one.

Earlier Linux controls prove FullEnforcement for their native LSP and executor
snapshots. Darwin helper controls prove BestEffort only. Neither substitutes for
an owner on one physical host driving the other host's executor on this exact
candidate. Earlier Launch-readiness and code-mode timing failures passed later
runs without a demonstrated causal fix; retain that uncertainty.

## 8. Pending decisions and external prerequisites

These are explicit pending choices, not authorization inferred from elapsed time
or from the October 7 push request.

| Decision | Concrete proposal | Why it matters |
| --- | --- | --- |
| Typed weft delivery | [Detached selector proposal](review/distributed-runtime-handoff-2026-10-07/weft-detached-selector-proposal.md), exact dependency revision and publication. | Required to finish original Compile aggregate delivery without lost replies. |
| Executor metadata reader | [Existing host-reader proposal](review/distributed-runtime-handoff-2026-10-07/registered-metadata-reader-proposal.md): executor depends on `host` and uses `read_bounded` with 131,072 bytes per metadata file. | Actual Prepare readiness must inspect bounded bytes, not trust a recipe exit code. |
| Local full-gate prerequisite | Install `flock`; change twenty seconds for all Python discovery to twenty seconds per module, preserving every test. | Full gate currently stops before packages. Neither change has been applied. |
| Simulation fixture ordering | A test-only rendezvous change so scripted DuringCall steering and the injected write fault both occur in the intended order. | Moving the callback before the fault alone lets Abort kill the caller before fault injection. Do not remove convergence assertions. |
| C3 limits and receipt API | [Outbox proposal](review/distributed-runtime-handoff-2026-10-07/peer-outbox-policy-proposal.md): 1-MiB complete envelope/receipt, 64-MiB charged outstanding custody, 64-row ceiling, exact-cell reader, explicit Confirmed retirement. | Changes acceptance and history behavior. Oversized legacy receipt remains unverified and charged; no permanent sender-local history after retirement. |
| Hook transcript representation | Define an approved executor-visible representation for registered hook payloads. | An owner SQLite pathname is not an executor path. |

The first five have concrete proposals or diagnosed paths; the transcript
representation remains an assembly design decision. Normal deployment still
needs usable authenticated host access and explicit approval before transferring
private workspace material. Do not spend a new session repeatedly probing an
unavailable remote machine while local assembly is incomplete.

## 9. Next work, in dependency order

1. **Repair and finish source acquisition in its existing isolated branch.**
   Fix the missing-row classification, compile the final expiration checks,
   execute the owner/actor/acquisition controls and close the concrete gaps in
   section 5. Keep the accepted size policy and source inventory. Obtain the
   required independent review, then import the reviewed delta onto the refreshed
   integration branch. Exit: the real fixed source bundle survives observer loss
   without new authority and refuses invalid/expired evidence.
2. **Bind ordinary startup to the original owner and prepared hooks.** Trace
   `daemon/main` through `serve.resolve_managed` and `assemble_in_domain` first.
   Use the integrated original-writer Effects constructor and prepared counter;
   carry cleanup into the runtime drain. Preserve ordinary local behavior.
   Exit: normal registered selection reaches real hook acquisition and gate
   construction, without probing the executor checkout on the owner.
3. **Finish the original physical-close prerequisites.** Resolve the typed-weft
   decision before resuming the blocked Compile adapter. Complete workspace
   aggregate and Launch channel original joins, then the finite LSP enclosing
   Service, failed-row charges, result retirement and drain. Exit: FullHost can
   close from actual original witnesses; lost/abnormal evidence stays uncertain.
4. **Complete the registered host/admin composition and default consumers.**
   Bind the actual pool and original registry/journals, one owner Broker and
   custodian, exact-generation publication, bounded authenticated historical
   access and the sole scope administrator. Wire ordinary tools, code mode,
   jobs, complete reports, cwd, guidance, Git, hooks and LSP. Exit: a normal
   remote session performs these operations with no owner checkout; close and
   restore preserve history and admit only proved-clean successors.
5. **Package roles and run both physical placements.** Extend the shipped
   entrypoints and existing launch utility capability checks. Exercise normal
   effects, cancellation, partition, restart, lost replies and generation
   replacement. Record revision, actual platform/enforcement, commands, exits
   and lifecycle witnesses for each direction. Exit: the same candidate passes
   both directions, followed by multiple-container operation.
6. **Finish executor pools and C1-C3/M1.** Use the issue/API plan for ownership,
   trusted routing, durable messaging and controlled movement. The Khepri probe
   is compatibility evidence only; no production dependency was adopted by that
   probe. Exit: the required issue phases have concrete default-host behavior
   and executable failure-path acceptance, without automatic failover or
   workspace snapshot migration.
7. **Freeze and validate the whole candidate.** Refresh main only when ready
   for an integration checkpoint, resolve approved test infrastructure changes,
   run full repository/shipped/model gates, and perform one independent final
   review of the assembled system. Exit: exact-head local, Linux, hosted and
   physical evidence meet the integration checklist. Keep the PR draft until
   then; obtain merge authorization separately.

The source-acquisition WIP defect is the first coding step. C3 is later required
scope, not the next reason to delay that step. The blocked Compile branch can
wait for its API decision without blocking independent hook work.

## 10. Reproduce checks without repeating the detours

Read root/package instructions and `docs/execution.md` before running gates.
The latest canonical local environment used Gleam 1.19.0 from the installed
server toolchain, OTP 29 / ERTS 17.0.5, Go 1.26.1 on Darwin arm64, and
`ERL_FLAGS='+S 4:4'`. Set the installed toolchain and Homebrew tools ahead of
injected tool binaries; use GNU `realpath` for the signoff driver.

```sh
export PATH="$HOME/.local/lib/loom/server/bin:/opt/homebrew/opt/coreutils/libexec/gnubin:/opt/homebrew/bin:$HOME/go/bin:$HOME/.dotnet/tools:$HOME/.dotnet:$PATH"
export ERL_FLAGS='+S 4:4'
export LOOM_TEST_SCRATCH="$HOME/.loom-cmtest/gates1007"
```

Choose a short isolated scratch directory for any new concurrent worktree.
The checkout itself must stay outside `/tmp`, where the jail substitutes its
scratch tmpfs. Do not copy dependency builds or normal code-mode seeds between
checkouts. Generate the normal seed with `make codemode-seed` after relevant
compiler/source changes. Serialize gates that share generated artifacts.

The repository runner accepts exact generated-module selectors, for example:

```sh
bash scripts/test.sh storage --match 'storage@owner_generations_test:'
bash scripts/test.sh client --match 'client@remote@registered_custodian_test:'
bash scripts/test.sh client --match 'client@remote@hook_source_acquisition_test:'
```

Verify the selector exists and actually executes the expected number of tests.
For shipped controls, build `make server-shipment`, then set
`LOOM_BOOTSTRAP_E2E_SERVER` to that checkout's `bin/loomd` and use the existing
fixture provider key (`loom-provider-fixture-key`, not a real credential).
A full `make check-client` without the server variable excludes thirteen shipped
fixtures and cannot replace the shipped run.

Record the command's own exit and source revision before reading its log. A
wrapper or `tail` exit is not the gate result. Distinguish command exit zero from
assertion count, explicit prerequisite exclusions and EUnit skips. The committed
receipt file demonstrates the format used here.

A restricted run failed TLS distribution before its tests (`eperm` on listen).
Fresh permissioned host runs were recorded separately. A sandbox denial is not
evidence of a product defect, and a permissioned retry does not make the original
run pass. Do not retry by silently disabling the sandbox.

The full Python gate is still blocked by its aggregate deadline and missing
`flock`. The installer/signoff sources are byte-identical to integrated main.
Simulation seed 997 also reproduces on clean main. Those facts narrow causality;
they do not waive the gates or authorize a changed deadline.

## 11. CI observed during checkpoint publication

The first checkpoint push started
[CI run 37670320089](https://github.com/Roasbeef/loom/actions/runs/37670320089)
at integration head `1c50b074f`. Both stock-compiler jobs failed during release
assembly with exit 2:

```text
Duplicated modules:
    executor_distribution_fixture_ffi specified in executor and client
```

This is a new recorded release blocker, not the earlier Python prerequisite
failure. Both completed job logs were read directly. The duplicate fixture
module is present in the executor and client test trees; the next session must
inspect how release assembly includes those artifacts and preserve both test
uses when fixing their naming or packaging. No fix was attempted after the pause.
The Linux/macOS dependencies, Linux static, runtime/storage/session/events,
conformance and 200-seed soak jobs had passed when checked; other jobs were still
running. The run as a whole was not green. Documentation pushes create a new
head, whose checks must be assessed separately.

The old `docs/next.md` statement that publication was unauthorized is superseded
by the explicit October 7 checkpoint request. Its earlier component-success
claims remain revision-scoped. This pause adds no new runtime acceptance, no
removal of a test and no relaxed assertion. Resume from the named defects and
unbuilt joins, not from an assumption that the large amount of code means the
product is almost done.
