# Current handoff

This file describes the current integration boundary, its evidence and the next
required work. Rewrite it after each integration milestone. This edition is
baselined against `a1ab45a02` on October 7, 2026, in the isolated
`runtime/main-refresh` branch. Source joins, gate receipts and hosted state were
checked for this edition; earlier component results are identified separately.

The branch now includes main at `142eba4a3b0dca245993851b893e7479c70d50c7`.
All 290 topic commits were rebased in their original order. The previous edition
said that this main revision was not integrated and that catalogue/protocol
collisions still needed resolution. Both statements are now false. Typed
workspace creation composes with main's model profiles, the catalogue handles
both historical version-nine layouts, and the registered proposals are numbered
078 and 079. Ordinary registered assembly and separate-host acceptance remain
unfinished.

## Where the tree is

[PR #819](https://github.com/Roasbeef/loom/pull/819) was last verified open and
draft at `b3bc47efdb2be7df421287aa437debdd034af9e5`, with no hosted checks on
that head. [Issue #697](https://github.com/Roasbeef/loom/issues/697) remains open.
The integration work is local; publication and merge are not authorized.
The integrated main revision has a
[passing CI run](https://github.com/Roasbeef/loom/actions/runs/37606780540).
That result belongs to main, not the unpublished integration candidate.

| Boundary | Current integration state |
| --- | --- |
| Owner custody and semantic transport | `05a02a788` wires registered admission, historical reopen and receipt readback to the original actor/connection/path. Original inputs, results, finite TLS BEAM controls, native forwarding and semantic consumers are implemented. Default daemon construction remains pending. |
| Native system and workspace identity | `bd2636b22` through `0ef51ba27` retain derived workspace commands, pending system ordinals and original live permission through the Broker. Real owner COMMIT/readback and composed ordinary receipt routing are integrated. Registered goal callers are integrated at `62c9b8ee7`; hook callers and full host wiring remain pending. |
| Compile and Launch | Immutable Original/UnusedImportRewrite attempts, consumed streams and exact-helper retirement compose in component controls. Default registered assembly remains pending. |
| Managed endpoint | `cfa36faa9` binds publication and removal to the original registry writer, concrete services and endpoint lifetime. It retains bounded digest receipts without restoring lost credits. Actual physical retirement and full scope administration remain pending. |
| Original startup and close witnesses | `ebc1a1417` validates the original live registry claim and exact Plan. `124bd33e2` retains native scope-close evidence before Service exit. FullHost still must bind the real pool and original joins; workspace, Compile and Launch witness work remains pending. |
| Helper consumption | `a69bc30b0` adds bounded input/output consumption credits and current-version wire decoding. |
| Original helper return | `0a2e46d95` retains the original finite protocol row until the exact pool acknowledges its Available transition. Real helper reuse and both consumption/release orders pass. Service failed-row admission accounting and finite LSP assembly remain pending. |
| Generation history | `e8410fd0d` and `c6f647f32` add permanent original provenance. `6fada9a53` adds restricted managed recovery of native, workspace and resource journals, with explicit close and original normal-exit evidence. Actual physical join validation and bounded history transport remain assembly obligations. |
| LSP | `e087fa42d` and `29bf7ecab` retain original custody and generated SQL. `3e78e49df` and `07fc05947` add reviewed bounded parsing and consumed transport/state. `d2ed9204d` and `8d51896d6` add original first-placement native custody and credited ServerLease transport, including actual Linux FullEnforcement controls. `787ab6eba` adds owned live startup and restricted recovery. `98c6fe01c` adds finite plan verification and retained collection. Actual Service ownership, semantic/result retirement and ordinary assembly remain pending. |
| Deployment | `54be793bb` and `c2f30387d` commit reviewed strict owner/executor loaders and their manifest. Shipped role bootstrap, admin transport, full host activation and ordinary daemon assembly remain unbuilt. |
| Launch utilities | `00a753071` supplies named private role bundles, selected export, lifecycle commands and a setup guide. Current images deliberately lack runtime capability labels and cannot pass its startup gate. |
| Distributed orchestration | Executor pools, C1 ownership, C2 routing, C3 durable cross-node messaging and M1 controlled movement remain required. |

The [integration guide](design-notes/distributed-runtime-integration.md) records
full acceptance criteria. The [setup guide](distributed-setup.md) distinguishes
prepared bundles, packaged role support and actual physical execution. Earlier
review records describe their stated source revisions, not the entire current
candidate.

## Verification and its limits

The full repository gate is red at `a1ab45a02`. `make check` exits two after
34.97 seconds, during its Python self-tests and before the package or release
integration gates. The aggregate Python deadline is twenty seconds. Isolated
host runs pass all eight installer tests and the six signoff-driver controls;
restricted process inspection had prevented installer pruning. The driver also
needs the installed GNU `realpath` on PATH. The remaining signoff gate cannot
acquire its lock because this Mac has no `flock`. These installer and signoff
sources are byte-identical to integrated main. A local prerequisite and a
per-module twenty-second budget are proposed, not applied; every test and the
existing gate remain intact.

`make model-check` also exits two, after 568.01 seconds. Of 196 declared cases,
`tcCompileReadySubmitUnassociated` reports failure; the other 195 report their
expected outcome. A strict unchanged run passes all 1,000 schedules at seed 697,
but seed 698 reproduces a null-target send at schedule 251. The directed scenario
releases a deferred association before the actual callback has arrived. That is
a model-driver defect; its correction and production correspondence remain under
review. The first green retry does not close the original failure. The existing
Lean gate passes its twelve admission theorems and all 684 comparisons with the
production reducer on the same candidate. Strict model-local witness and mutation
gates and the TLA+ ownership checks still need current receipts.

The registered goal integration at `62c9b8ee7` passes all 3,260 client tests:
381.46 seconds of tests, 402.66 seconds including build, with the command's own
exit zero. Normal seed, formatting, client lint, documentation and prelude gates
pass; all seven imported file hashes remain unchanged. Client lint reports zero
errors and 571 warnings. The fifteen explicit optional exclusions are thirteen
shipped-server controls, the Linux `/proc` witness and rust-analyzer. They do not
satisfy shipped registered-host acceptance. The worker separately passed all
3,170 tests on its older component base.

The twelve new controls use actual conversation SQLite, original owner custody,
Broker admission and Dispatcher cancellation. They cover lost COMMIT replies,
changed readbacks, replay, original deadlines, late receipts and current actor
publication. Their held or NotStarted transport does not establish physical
helper effects. Independent review found one missing GoalChanged publication;
calling the existing publisher after successful retention fixes it. The actual
bus assertion fails under an omitted-publication mutant, and the same reviewer
closed the finding. The pre-fix 3,169-test receipt remains separate evidence.

The rebased candidate passes the complete storage gate: 274 tests, with the
command's own exit zero. Ninety-seven focused client controls pass across daemon
protocol, server, manager, domain resolution, TUI encoding and UI profile
selection. Client and conformance builds pass. Normal SQL generation produces
no further diff. Formatting, affected lint, configuration-key, documentation and
prelude gates pass. Documentation reports zero errors and 193 warnings; lint
reports warnings, not a warning-free lint census. All 23 launcher tests pass
with the existing image compatibility token.

The first composed documentation gate failed on stale symbol citations and the
configuration-key registry's old LSP profile path. Those references are corrected
and the gate passes on its own subsequent exit. A source census found no named
test removed from the 120 upstream-changed test files. That census checks
preservation; it does not replace execution of those tests.

Independent rebase review found no unresolved source issue. Two low documentation
errors were corrected: the catalogue header still named version nine, and a
model-profile link had followed the unrelated registered-LSP renumbering. The
review traced profile/binding creation retries, SQL field positions, feature
refusal before local probes, and main's cache and peer-policy additions.

`17cfe2403` composes typed workspace creation with profile selection.
`e6aa65d68` makes catalogue version ten preserve recent folders, profiles and
workspace bindings. Historical version eight accepts either folders or bindings
and installs the missing addition plus profiles. Historical version nine requires
folders and exactly one of the two columns, then installs the missing column.
Malformed or mixed historical shapes refuse without advancing. DDL and the
version update share the existing transaction. Real SQLite controls retain rows,
authentication, memberships, defaults and profiles; a column-limit fixture makes
the second DDL fail and proves rollback of the first. Two compiled omission
mutants fail their intended SQL assertions. The worker's 274-test result is
separate from the composed root's 274-test result above.

The earlier identity foundation passed core/storage/broker/client/executor
component gates with 213/264/461/3158/547 tests before this rebase. Original helper
return passed all 474 broker tests, and its real-helper control passed both
consumption/release orders followed by another command on the same helper.
That helper run used Darwin BestEffort, not Linux FullEnforcement. The finite
collector passed executor/tools/code-mode gates with 547/755/483 tests.
These receipts establish their original component revisions; they are not full
post-rebase gate results.

The identity review corrected ordinary native commands being routed to semantic
Git, and strengthened cancellation to assert durable automatic cleanup before
manual cleanup. Its earlier wrong-receiver fixture is withdrawn as held-worker
evidence. The helper-return review found no actionable issue. Its original row
stays retained until the actual pool acknowledges check-in; failed return rows
remain charged until Service close. Pool capacity alone does not bound those rows.

Earlier Linux native-LSP controls proved FullEnforcement for initialize/hover,
graceful stop and a native Completed/ProtocolComplete terminal. They independently
observed native retirement and managed drain. Earlier Linux executor and sandbox
checks likewise covered their stated component snapshots. None establishes an
assembled owner on one physical machine driving the other machine's executor,
or same-candidate acceptance in both placements.

Two earlier timeout causes remain unresolved. A Launch readiness failure passed
later diagnostic retries without a demonstrated startup fix. A code-mode build
control passed alone and in subsequent unchanged full runs without a proved
cause. Their original failures remain evidence; no assertion, deadline or test
was removed to obtain green runs. Earlier optional client exclusions include
one Linux `/proc` witness, thirteen shipped-server controls and rust-analyzer;
those exclusions do not satisfy shipped-runtime acceptance. A large-array
JavaScript parser probe still reaches the existing sibling-recursion stack limit
in both parser profiles.

Full repository gates, shipped registered tools, both physical-host placements,
container execution and hosted CI have not passed on this candidate.

## What to do next

1. Implement ordinary registered hooks for **#697** using original indexed
   trusted sources and one immutable occurrence before execution. Goal callers
   are integrated, including actual Checking persistence and UI publication.
   **Exit:** all five existing hook gates retain original source/handler identity,
   stdin and deadlines; cancellation and uncertain writes cannot create new
   work; local behavior and all tests remain intact. Source acquisition and
   normal daemon selection then compose through the actual registered host.
2. Complete original physical-close prerequisites. **Exit:** workspace aggregate,
   Compile preparation and Launch channel ownership supply their actual original
   close witnesses; finite LSP Service ownership retains failed-row charges,
   semantic results and managed drain. The collector and exact pool return are
   integrated, but do not supply the enclosing Service proof.
3. Assemble the approved ordinary path from protocols 078 and 079. Preserve one
   original owner Broker/custodian, exact-generation publication, executor-only
   physical paths, full reports, jobs, hooks, cwd, guidance, Git and LSP.
   **Exit:** default tools and code mode run with no checkout on the owner, and
   Close/restore retains history and permits only proved clean successors.
4. Complete role packaging and both physical-host placements, followed by
   executor pools and C1-C3/M1. **Exit:** the same candidate passes normal effects,
   cancellation, partition, restart, lost-reply, routing, durable messaging and
   controlled movement. Automatic failover and workspace snapshot migration stay
   outside the approved scope.
5. Check for later main changes, run applicable model and full repository gates,
   and review the assembled system. **Exit:** exact candidate evidence closes
   the integration checklist before publication or merge is requested.

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
[Protocol 079](../protocol-change/079-registered-generations.md) selects sixteen
live/unretired slots, 4,096 permanent identities and 256 MiB of logical metadata.
Original removal acknowledgement and durable Removed precede slot reuse.
Uncertain custody stays charged. Successors retain immutable original owner
and system-child links; history reads and receipts cannot repeat an effect.

**Workspace native commands retain their semantic parent.** The approved
[protocol-079 addendum](../protocol-change/079-registered-generations.md#addendum-native-identity-beneath-a-workspace-request)
uses a distinct deterministic identity beneath the exact retained Workspace or
system semantic request. It preserves the original quota group and adds no
system ordinal. Admitted capabilities retain their existing purpose pair.
Standalone native system commands separately reserve original identity before
Broker clearance and admit exact cleared bytes afterward. These identity and
sequencing changes are integrated at the custodian and Broker boundary. Registered
goal callers are integrated; hook callers and full host wiring remain
unimplemented. Initialize does not imply an invented native setup command.

## Deliberately open

The approved [LSP contract](../protocol-change/078-registered-lsp.md) and
[administration contract](../protocol-change/079-registered-generations.md) define
required implementation work. Full activation, original physical retirement and
normal daemon assembly are unbuilt, not accepted limitations of the final
feature. Durable original journal/enrollment provenance and restricted managed
recovery of native, workspace and resource writers are integrated. Original LSP
live startup and restricted recovery are also integrated.
Finite Service ownership, the sole scope administrator and authenticated bounded
history transport remain assembly prerequisites. C1-C3 and M1 also remain
required by **#697**.

Two concrete proposals await owner approval: a typed Detached selector in weft
with the exact Loom dependency-pin update, and the executor's existing-host
metadata reader dependency. The selector supplies managed outcomes without
losing the independent original scope monitor. The metadata reader supplies
bounded actual Prepare readiness. Neither proposal is implemented or approved by
elapsed time; independent implementation continues around these boundaries.

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
