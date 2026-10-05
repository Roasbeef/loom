# Distributed runtime integration

Status: implementation in progress for [issue #697](https://github.com/Roasbeef/loom/issues/697).

The work now uses one draft integration PR against `main`. The earlier component
PRs preserve their review discussions, but the integration branch is the place
to review the complete system. Component commits remain separate so a reader can
follow the dependency order without opening dozens of PRs.

## Start with the ownership model

The [design](distributed-runtime.md) describes the user journeys and trust
boundaries. The [API plan](distributed-runtime-api.md) maps those decisions to
implementation phases. A workspace stays on its registered executor. The owning
orchestrator retains the session's SQLite store, approval authority and budget.
Clients can reconnect to that owner from another device without moving files.

The owner has selected TLS-protected BEAM distribution for trusted executors
as well as orchestrators. This replaces the original custom framed TLS adapter;
the replacement is in progress. Executors join the same runtime trust domain,
while model-authored satellites remain distribution-disabled in their native
sandboxes. A compromised executor VM can compromise connected orchestrator
runtimes. Executor membership does not grant Raft voting membership. The
[protocol amendment](../../protocol-change/067-remote-workspace-services.md#addendum-trusted-executor-distribution)
defines the boundary and replacement gates. A live BEAM process is never a
durable ownership record.

## Read the components in this order

| Component | Responsibility | Reading entry |
|---|---|---|
| Identities and admission | Bind requests to the executor, workspace and original operation; keep unknown outcomes distinct from retry permission. | [Protocol 066](../../protocol-change/066-distributed-runtime-foundations.md), `executor/remote/identity`, `executor/remote/admission`. |
| Owner custody | Retain exact input, native commands and results under the original owner; commit receipts before acknowledgement. | [Owner custody architecture](../architecture/remote-custody.md), `client/remote/custodian`, `storage/owner_custody`. |
| Native execution | Authenticate routes, bound ingress and output, retain native evidence, and join the existing helper lifecycle. | [Native service review](../review/distributed-native-service.md), `executor/remote/service`, `executor/remote/host`. |
| Workspace operations | Run semantic filesystem operations beside the authoritative checkout and recover retained outcomes. | [Workspace host review](../review/distributed-workspace-host.md), [workspace exchange review](../review/distributed-workspace-exchange.md). |
| Physical compilation | Prepare executor-owned sources, preserve original authority through compiler admission, and retain the finalized artifact result. | [Remote compilation architecture](../architecture/remote-compilation.md), [protocol 067](../../protocol-change/067-remote-workspace-services.md). |
| Language servers | Keep physical queries, preparation, rename and diagnostics beside the executor checkout; retain owner approval. | [Remote LSP integration status](../architecture/lsp.md#remote-executor-integration-status). |
| Ownership and recovery models | Check bounded ordering claims and compare selected pure properties with implementation behavior. | [PlusCal/TLA+](../../protocol/models/distributed-authority/README.md), [P](../../protocol/models/remote-execution/README.md), [Lean](../../protocol/models/admission-proof/README.md). |

Package `CLAUDE.md` and its identical `AGENTS.md` mirror describe concrete types,
messages and dependency edges. Source module documentation explains the local
ownership and failure rules. The architecture guides connect those modules across
packages; the review records separate measured behavior from remaining obligations.

## Current integration boundary

The branch contains the native executor, owner custody, semantic workspace
operations, bounded transport and physical compilation components. These have
focused tests and independent review records. Their presence does not enable
the complete distributed workflow in the shipped daemon.

Whole Compile ownership, native command forwarding and the owner consumer now
run through the trusted TLS BEAM endpoint in the integration branch. Combined
owner/Compile/workspace controls and native executor/owner restart tests pass
against the merged Weft revision. The [transport transition record](../review/distributed-beam-transport-transition.md)
keeps the transport evidence. The historical-route refusal correction and
scoped endpoint/native-close changes now pass independent review and combined
package gates; the [lifecycle review](../review/distributed-scoped-lifetime-runtime.md)
records their remaining enclosing-host obligations.
The reviewed [scoped lifetime proposal](distributed-scope-lifetime.md) describes
the next host boundary; the owner approved its API and native close-state change.
The [final-result proposal](distributed-final-results.md) records the separate
accepted Launch result representation and its remaining retention mechanics.
Launch/satellite execution, the remote LSP host and registered daemon
configuration remain required. Acceptance must drive ordinary tools and code
mode with the owner and executor on separate hosts and no checkout on the
owner's disk.

Executor pools, trusted orchestrator routing, durable cross-node messaging and
controlled session movement follow that first working remote path. These are
required remaining work for issue #697. In the API plan, C1 implements the
ownership service, C2 adds TLS BEAM membership and routing, C3 adds durable
cross-node messaging, and M1 adds planned session movement. None is complete
merely because remote executor requests can cross a TLS connection.

The [Khepri compatibility probe](../review/distributed-khepri-compatibility.md)
passed bounded Gleam/OTP 29, three-member partition, receipt-reconciliation and
restart controls. The wrapper's production decoder, retention lifecycle and
remaining D3 operational checks are still open; no dependency is adopted here.
Automatic failover and workspace snapshot migration remain deferred.

## How changes enter the integration branch

Workers own disjoint implementation slices in isolated worktrees. Each slice
includes literate module documentation, package maps, focused controls and the
relevant lint/generated-source gates. Independent review checks the consequential
invariants and reachable failure paths before the root integrates the commits.
Architecture docs change with the component they describe.

Focused checks run as components arrive. Full repository and integration gates
run at meaningful integration milestones, with one final adversarial signoff
over the complete candidate. Changes made after that signoff require the checks
their scope warrants. A prior component pass cannot stand in for a current
assembled-system result.

The branch must incorporate current `main` before final validation. The original
37 component PR heads were checked against the consolidation head: 36 are direct
ancestors, and the remaining documentation commit has a patch-equivalent
cherry-pick. Their branches and review history remain available; consolidation
does not merge the implementation into `main`.

## Acceptance before merge readiness

- [ ] Integrate current `main` and pass its full repository gates.
- [ ] Exercise ordinary tools, code-mode Compile/Launch and LSP through registered remote consumers.
- [ ] Pass separate-host tests with the workspace absent from the owner, including cancellation, partition, restart and lost replies.
- [ ] Run the applicable formal-model gates and document the implementation correspondence and proof limits.
- [ ] Complete the remaining issue phases and a final adversarial review of the assembled system.

The PR stays draft while these obligations are unfinished. Each milestone must
record its exact source revision, command exit, skipped coverage and remaining
limits. A successful helper fixture, green component test or bounded model run
alone cannot establish product acceptance.
